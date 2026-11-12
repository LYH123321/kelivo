import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../models/assistant_regex.dart';

/// Parses a SillyTavern regex script JSON file. Accepts either a single
/// script object, a bare list of scripts, or a full ST "regex settings"
/// export where scripts live under `scripts` / `regex_scripts`.
/// Mirrors ST's own field semantics: only `disabled` (or explicit
/// `enabled: false`) marks a rule off — everything else imports enabled.
List<AssistantRegex> parseStRegexJson(String raw) {
  final dynamic decoded = jsonDecode(raw);
  List<dynamic> scripts;
  if (decoded is List) {
    scripts = decoded;
  } else if (decoded is Map) {
    final m = decoded.cast<String, dynamic>();
    final cand = m['scripts'] ?? m['regex_scripts'] ?? m['regex_rules'];
    if (cand is List) {
      scripts = cand;
    } else {
      scripts = [decoded];
    }
  } else {
    throw const FormatException('regex json root is not object/list');
  }
  final rules = <AssistantRegex>[];
  for (final item in scripts) {
    if (item is! Map) continue;
    final m = item.cast<String, dynamic>();
    final findRegex = (m['findRegex'] ?? m['pattern'] ?? '').toString();
    if (findRegex.isEmpty) continue;
    final scriptName = (m['scriptName'] ?? m['name'] ?? '').toString();
    final replaceString =
        (m['replaceString'] ?? m['replacement'] ?? '').toString();
    final disabled = m['disabled'] == true;
    final enabled = m.containsKey('enabled') ? (m['enabled'] == true) : (!disabled);
    final scopes = <AssistantRegexScope>[];
    final rawPlacement = m['placement'];
    if (rawPlacement is List) {
      for (final p in rawPlacement) {
        if (p == 1 || p == '1' || p == 'user') scopes.add(AssistantRegexScope.user);
        if (p == 2 || p == '2' || p == 'assistant') {
          scopes.add(AssistantRegexScope.assistant);
        }
      }
    }
    // ST: markdownOnly => display-only (visual), promptOnly => affects prompt
    // only (replace). Neither set means it affects both.
    final markdownOnly = m['markdownOnly'] == true;
    final promptOnly = m['promptOnly'] == true;
    rules.add(
      AssistantRegex(
        id: (m['id'] ?? '').toString().isEmpty
            ? const Uuid().v4()
            : (m['id']).toString(),
        name: scriptName.isEmpty ? 'Regex' : scriptName,
        pattern: findRegex,
        replacement: replaceString,
        scopes: scopes.isEmpty
            ? const [AssistantRegexScope.user, AssistantRegexScope.assistant]
            : scopes,
        visualOnly: markdownOnly && !promptOnly,
        replaceOnly: promptOnly && !markdownOnly,
        enabled: enabled,
      ),
    );
  }
  if (rules.isEmpty) throw const FormatException('no regex rules found');
  return rules;
}
