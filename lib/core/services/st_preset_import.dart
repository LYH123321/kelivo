import 'dart:convert';

import '../models/assistant.dart';
import '../models/preset_message.dart';

/// npu17: SillyTavern preset (chat completion preset JSON) importer.
///
/// ST presets contain a `prompts` list ({name, system_prompt, role, content,
/// identifier}) plus a `prompt_order` list describing enabled state & order.
/// We map enabled prompts in order: system-role contents are appended to the
/// assistant systemPrompt; user/assistant contents become presetMessages.
/// Sampling params (temperature / top_p / max tokens) are mapped too.
class StPresetImportResult {
  final String systemPromptAddition;
  final List<PresetMessage> presetMessages;
  final double? temperature;
  final double? topP;
  final int? maxTokens;
  final int importedCount;
  final int skippedCount;
  const StPresetImportResult({
    required this.systemPromptAddition,
    required this.presetMessages,
    required this.temperature,
    required this.topP,
    required this.maxTokens,
    required this.importedCount,
    required this.skippedCount,
  });
}

/// Identifiers that are placeholders / handled natively by Kelivo
/// (chat history, char fields, world info). Their content is usually empty;
/// skip them even if non-empty to avoid duplicating char data.
const List<String> _kSkipIdentifiers = [
  'chatHistory',
  'dialogueExamples',
  'charDescription',
  'charPersonality',
  'scenario',
  'personaDescription',
  'worldInfoBefore',
  'worldInfoAfter',
  'enhanceDefinitions',
  'nsfw',
  'jailbreak',
  'main',
];

/// Parse a SillyTavern chat-completion preset JSON string.
/// Throws [FormatException] on invalid JSON / missing fields.
StPresetImportResult parseStPresetJson(String raw) {
  final dynamic decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('preset root is not an object');
  }
  final promptsRaw = decoded['prompts'];
  if (promptsRaw is! List || promptsRaw.isEmpty) {
    throw const FormatException('no prompts array');
  }
  // identifier -> prompt map
  final byId = <String, Map<String, dynamic>>{};
  for (final p in promptsRaw) {
    if (p is Map) {
      final m = p.map((k, v) => MapEntry(k.toString(), v));
      final id = (m['identifier'] ?? '').toString();
      if (id.isNotEmpty) byId[id] = m;
    }
  }
  // Ordered enabled identifiers from prompt_order (ST uses character_id
  // 100001 for the active preset ordering). Fall back to prompts order.
  List<Map<String, dynamic>> ordered = <Map<String, dynamic>>[];
  final poRaw = decoded['prompt_order'];
  if (poRaw is List) {
    for (final entry in poRaw) {
      if (entry is! Map) continue;
      final orderRaw = entry['order'];
      if (orderRaw is! List) continue;
      final tmp = <Map<String, dynamic>>[];
      for (final o in orderRaw) {
        if (o is! Map) continue;
        final enabled = o['enabled'] == true;
        if (!enabled) continue;
        final id = (o['identifier'] ?? '').toString();
        final prompt = byId[id];
        if (prompt == null) continue;
        tmp.add(prompt);
      }
      if (tmp.isNotEmpty) {
        ordered = tmp; // keep last matching group (active one)
      }
    }
  }
  if (ordered.isEmpty) {
    ordered = promptsRaw
        .whereType<Map>()
        .map((p) => p.map((k, v) => MapEntry(k.toString(), v)))
        .toList();
  }

  final sysParts = <String>[];
  final preset = <PresetMessage>[];
  var imported = 0;
  var skipped = 0;
  for (final p in ordered) {
    final identifier = (p['identifier'] ?? '').toString();
    final content = (p['content'] ?? '').toString().trim();
    if (content.isEmpty) {
      skipped++;
      continue;
    }
    if (_kSkipIdentifiers.contains(identifier)) {
      skipped++;
      continue;
    }
    final role = (p['role'] ?? (p['system_prompt'] == true ? 'system' : 'system'))
        .toString();
    if (role == 'user' || role == 'assistant') {
      preset.add(PresetMessage(role: role, content: content));
    } else {
      sysParts.add(content);
    }
    imported++;
  }

  double? temperature;
  final tempRaw = decoded['temperature'];
  if (tempRaw is num && tempRaw >= 0 && tempRaw <= 2) temperature = tempRaw.toDouble();
  double? topP;
  final topPRaw = decoded['top_p'];
  if (topPRaw is num && topPRaw > 0 && topPRaw <= 1) topP = topPRaw.toDouble();
  int? maxTokens;
  final mtRaw = decoded['openai_max_tokens'] ?? decoded['genamt'];
  if (mtRaw is num && mtRaw > 0) maxTokens = mtRaw.toInt();

  return StPresetImportResult(
    systemPromptAddition: sysParts.join('\n\n'),
    presetMessages: preset,
    temperature: temperature,
    topP: topP,
    maxTokens: maxTokens,
    importedCount: imported,
    skippedCount: skipped,
  );
}

/// Apply a parsed ST preset onto an [Assistant], returning the updated copy.
/// System additions replace the system prompt (they carry the full preset
/// main/jailbreak text); preset messages are replaced wholesale.
Assistant applyStPresetToAssistant(Assistant a, StPresetImportResult r) {
  return a.copyWith(
    systemPrompt:
        r.systemPromptAddition.isEmpty ? a.systemPrompt : r.systemPromptAddition,
    presetMessages: r.presetMessages,
    temperature: r.temperature ?? a.temperature,
    topP: r.topP ?? a.topP,
    maxTokens: r.maxTokens ?? a.maxTokens,
  );
}