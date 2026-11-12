import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:uuid/uuid.dart';
import '../models/assistant_regex.dart';

/// Character card (V2/V3) importer for Kelivo.
///
/// Supported formats:
/// - PNG with `chara` (V2, base64 JSON in tEXt chunk) and/or `ccv3` (V3) chunks
/// - CHARX (zip container with card.json + assets)
/// - Plain JSON / charx-renamed JSON with spec `chara_card_v2` / `chara_card_v3`
///
/// V3 chunk takes precedence over V2 (same policy as RisuAI / SillyTavern).
class CharacterCardData {
  final String name;
  final String description;
  final String personality;
  final String scenario;
  final String firstMes;
  final String mesExample;
  final String systemPrompt;
  final String creatorNotes;
  final List<String> alternateGreetings;
  final String avatarPath; // extracted image (png card cover), may be ''
  final List<AssistantRegex> regexRules;
  final Map<String, dynamic> raw;
  const CharacterCardData({
    required this.name,
    this.description = '',
    this.personality = '',
    this.scenario = '',
    this.firstMes = '',
    this.mesExample = '',
    this.systemPrompt = '',
    this.creatorNotes = '',
    this.alternateGreetings = const <String>[],
    this.avatarPath = '',
    this.regexRules = const <AssistantRegex>[],
    this.raw = const <String, dynamic>{},
  });
}

class CharacterCardImportResult {
  final CharacterCardData card;

  /// Entries extracted from the embedded character_book, already shaped for
  /// direct conversion into Kelivo WorldBookEntry objects.
  final List<Map<String, dynamic>> lorebookEntries;

  const CharacterCardImportResult({required this.card, required this.lorebookEntries});
}

/// Minimal PNG tEXt/zTXt chunk reader.
/// Returns {keyword: text} for all text chunks found.
Map<String, String> parsePngTextChunks(Uint8List bytes) {
  final out = <String, String>{};
  // PNG signature: 89 50 4E 47 0D 0A 1A 0A
  if (bytes.length < 8 ||
      bytes[0] != 0x89 ||
      bytes[1] != 0x50 ||
      bytes[2] != 0x4E ||
      bytes[3] != 0x47) {
    return out;
  }
  var offset = 8;
  final bd = ByteData.sublistView(bytes);
  while (offset + 8 <= bytes.length) {
    final length = bd.getUint32(offset);
    final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
    if (type == 'IEND') break;
    if (type == 'tEXt' && offset + 8 + length <= bytes.length) {
      final data = bytes.sublist(offset + 8, offset + 8 + length);
      final nul = data.indexOf(0);
      if (nul > 0) {
        final key = latin1.decode(data.sublist(0, nul));
        final value = latin1.decode(data.sublist(nul + 1));
        out[key] = value;
      }
    }
    offset += 8 + length + 4; // len + type + data + crc
  }
  return out;
}

/// Decode a card payload (base64 or raw JSON string) into a V2/V3 map.
Map<String, dynamic>? decodeCardJson(String raw) {
  var text = raw.trim();
  Map<String, dynamic>? tryParse(String s) {
    try {
      final v = jsonDecode(s);
      if (v is Map) return v.cast<String, dynamic>();
    } catch (_) {}
    return null;
  }

  var map = tryParse(text);
  if (map != null) return map;
  try {
    text = utf8.decode(base64.decode(raw.replaceAll('\n', '').replaceAll('\r', '')));
    map = tryParse(text);
  } catch (_) {}
  return map;
}

/// Extract the inner `data` object from a V2/V3 card.
Map<String, dynamic> cardDataMap(Map<String, dynamic> card) {
  if (card['data'] is Map) {
    return (card['data'] as Map).cast<String, dynamic>();
  }
  return card;
}


List<AssistantRegex> _parseRegexRules(Map<String, dynamic> data) {
  final extensions = data['extensions'] is Map ? (data['extensions'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
  final scripts = data['regex_scripts'] ?? data['regex_rules'] ?? extensions['regex_scripts'] ?? extensions['regex_rules'];
  if (scripts is! List) return const <AssistantRegex>[];

  final rules = <AssistantRegex>[];
  for (final item in scripts) {
    if (item is! Map) continue;
    final m = item.cast<String, dynamic>();
    final scriptName = (m['scriptName'] ?? m['name'] ?? '').toString();
    final findRegex = (m['findRegex'] ?? m['pattern'] ?? '').toString();
    if (findRegex.isEmpty) continue;
    final replaceString = (m['replaceString'] ?? m['replacement'] ?? '').toString();
    final disabled = m['disabled'] == true;
    final enabled = m.containsKey('enabled') ? (m['enabled'] == true) : (!disabled);

    final rawPlacement = m['placement'];
    final scopes = <AssistantRegexScope>[];
    if (rawPlacement is List) {
      for (final p in rawPlacement) {
        if (p == 1 || p == '1' || p == 'user') scopes.add(AssistantRegexScope.user);
        if (p == 2 || p == '2' || p == 'assistant') scopes.add(AssistantRegexScope.assistant);
      }
    }
    if (scopes.isEmpty) {
      scopes.addAll([AssistantRegexScope.user, AssistantRegexScope.assistant]);
    }

    rules.add(AssistantRegex(
      id: (m['id'] ?? const Uuid().v4()).toString(),
      name: scriptName.isEmpty ? 'Regex' : scriptName,
      pattern: findRegex,
      replacement: replaceString,
      scopes: scopes,
      visualOnly: false,
      replaceOnly: false,
      enabled: enabled,
    ));
  }
  return rules;
}

CharacterCardImportResult? parseCharacterCard(
  Map<String, dynamic> card, {
  String avatarPath = '',
}) {
  final spec = card['spec'] as String? ?? '';
  if (spec.isNotEmpty &&
      spec != 'chara_card_v2' &&
      spec != 'chara_card_v3' &&
      spec != 'chara_card') {
    return null;
  }
  final data = cardDataMap(card);
  final name = (data['name'] ?? card['name'] ?? '').toString();
  if (name.isEmpty) return null;

  String s(Object? v) => (v ?? '').toString();

  final book = data['character_book'];
  final entries = <Map<String, dynamic>>[];
  if (book is Map) {
    final rawEntries = book['entries'];
    final list = rawEntries is List
        ? rawEntries.whereType<Map>().toList()
        : rawEntries is Map
            ? rawEntries.values.whereType<Map>().toList()
            : <Map>[];
    for (final e in list) {
      final content = s(e['content']);
      if (content.isEmpty) continue;
      final keys = e['keys'] is List
          ? (e['keys'] as List).map((k) => k.toString()).toList()
          : e['key'] is List
              ? (e['key'] as List).map((k) => k.toString()).toList()
              : e['key'] is String
                  ? <String>[e['key'] as String]
                  : <String>[];
      final enabledRaw = e['enabled'];
      final constantRaw = e['constant'];
      final rawSecondary = e['secondary_keys'] ?? (e['extensions'] is Map ? (e['extensions'] as Map)['secondary_keys'] : null);
      final secondaryKeys = (rawSecondary is List)
          ? rawSecondary.map((k) => k.toString().trim()).where((k) => k.isNotEmpty).toList(growable: false)
          : const <String>[];
      final selectiveLogicRaw = e['selectiveLogic'] ?? (e['extensions'] is Map ? (e['extensions'] as Map)['selectiveLogic'] : null);
      final useRegexRaw = e['use_regex'] == true ||
          (e['extensions'] is Map && (e['extensions'] as Map)['use_regex'] == true);
      entries.add({
        'id': const Uuid().v4(),
        'name': s(e['name'] ?? e['comment']),
        'enabled': enabledRaw is bool ? enabledRaw : true,
        'content': content,
        'keywords': keys,
        'secondary_keys': secondaryKeys,
        'selectiveLogic': selectiveLogicRaw is num ? selectiveLogicRaw.toInt() : 0,
        'use_regex': useRegexRaw,
        'constantActive': constantRaw is bool ? constantRaw : (keys.isEmpty),
        'position': s(e['position']),
        'extensions': e['extensions'] is Map
            ? (e['extensions'] as Map).cast<String, dynamic>()
            : const <String, dynamic>{},
      });
    }
  }

  final altGreetings = data['alternate_greetings'] is List
      ? (data['alternate_greetings'] as List).map((g) => g.toString()).toList()
      : <String>[];

  final regexRules = _parseRegexRules(data);
  final card2 = CharacterCardData(
    name: name,
    description: s(data['description']),
    personality: s(data['personality']),
    scenario: s(data['scenario']),
    firstMes: s(data['first_mes']),
    mesExample: s(data['mes_example']),
    systemPrompt: s(data['system_prompt']),
    creatorNotes: s(data['creator_notes']),
    alternateGreetings: altGreetings,
    avatarPath: avatarPath,
    regexRules: regexRules,
    raw: card,
  );
  return CharacterCardImportResult(card: card2, lorebookEntries: entries);
}

/// Parse a card from raw bytes: auto-detect PNG / CHARX / JSON.
CharacterCardImportResult? parseCharacterCardBytes(
  Uint8List bytes,
  String fileName,
) {
  final lower = fileName.toLowerCase();

  // CHARX = zip with card.json inside.
  if (lower.endsWith('.charx') || _looksLikeZip(bytes)) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      ArchiveFile? cardFile;
      for (final f in archive.files) {
        if (f.name == 'card.json' || f.name == 'Card.json') {
          cardFile = f;
          break;
        }
      }
      cardFile ??= archive.files.cast<ArchiveFile?>().firstWhere(
        (f) => f != null && f.name.toLowerCase().endsWith('.json') && !f.name.contains('/'),
        orElse: () => null,
      );
      if (cardFile != null && cardFile.name.isNotEmpty) {
        final json = decodeCardJson(utf8.decode(cardFile.content as List<int>));
        if (json != null) return parseCharacterCard(json);
      }
    } catch (_) {}
    // fall through: maybe a json file misnamed
  }

  if (lower.endsWith('.png') || _looksLikePng(bytes)) {
    final chunks = parsePngTextChunks(bytes);
    final raw = chunks['ccv3'] ?? chunks['chara'];
    if (raw != null) {
      final json = decodeCardJson(raw);
      if (json != null) return parseCharacterCard(json);
    }
    return null;
  }

  // Plain JSON.
  try {
    final json = decodeCardJson(utf8.decode(bytes));
    if (json != null) return parseCharacterCard(json);
  } catch (_) {}
  return null;
}

bool _looksLikeZip(Uint8List b) =>
    b.length > 4 && b[0] == 0x50 && b[1] == 0x4B && (b[2] == 3 || b[2] == 5 || b[2] == 7);

bool _looksLikePng(Uint8List b) =>
    b.length > 4 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;

/// Build a ready-to-use system prompt from card fields
/// (SillyTavern-compatible ordering).
String characterCardSystemPrompt(CharacterCardData c) {
  final parts = <String>[];
  if (c.systemPrompt.isNotEmpty) {
    parts.add(c.systemPrompt);
  } else if (c.description.isNotEmpty) {
    parts.add('{{char}}\'s description: ${c.description}');
  }
  if (c.personality.isNotEmpty) parts.add('{{char}}\'s personality: ${c.personality}');
  if (c.scenario.isNotEmpty) parts.add('Scenario: ${c.scenario}');
  return parts.join('\n\n');
}