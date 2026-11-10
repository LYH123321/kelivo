import 'dart:convert';
import 'dart:io';

import 'package:Kelivo/core/providers/mcp_provider.dart';
import 'package:Kelivo/core/services/mcp/mcp_config_import.dart';
import 'package:Kelivo/core/services/skills/skills_service.dart';
import 'package:Kelivo/shared/widgets/snackbar.dart';
import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// What a picked custom-import file turned out to be.
enum CustomImportKind { skill, mcp, unknown }

class _CustomSniffResult {
  const _CustomSniffResult(this.kind, [this.mcpJsonText]);
  final CustomImportKind kind;
  final String? mcpJsonText;
}

/// Universal "custom import": pick any .md / .zip / .json and it is routed
/// automatically:
/// - .md, or zip containing SKILL.md          -> installed as a skill
/// - .json with mcpServers, or zip containing such a JSON -> registered as
///   MCP plugin servers (real tool plugins)
Future<void> runCustomImport(BuildContext context) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['md', 'zip', 'json'],
  );
  final path = result?.files.single.path;
  if (path == null || !context.mounted) return;
  try {
    final sniff = await _sniff(path);
    switch (sniff.kind) {
      case CustomImportKind.skill:
        await context.read<SkillsService>().importFromFile(path);
        if (!context.mounted) return;
        showAppSnackBar(
          context,
          message: 'Skill installed',
          type: NotificationType.success,
        );
      case CustomImportKind.mcp:
        final text = sniff.mcpJsonText ?? await File(path).readAsString();
        final servers = parseMcpConfigImport(text);
        await context.read<McpProvider>().importServers(servers);
        if (!context.mounted) return;
        showAppSnackBar(
          context,
          message: 'Plugin installed (${servers.length} MCP server(s))',
          type: NotificationType.success,
        );
      case CustomImportKind.unknown:
        throw const FormatException(
          'Unrecognized file: zip must contain SKILL.md or a JSON with mcpServers',
        );
    }
  } catch (e) {
    if (!context.mounted) return;
    showAppSnackBar(
      context,
      message: 'Import failed: $e',
      type: NotificationType.error,
    );
  }
}

Future<_CustomSniffResult> _sniff(String path) async {
  final lower = path.toLowerCase();
  if (lower.endsWith('.md')) {
    return const _CustomSniffResult(CustomImportKind.skill);
  }
  if (lower.endsWith('.json')) {
    final text = await File(path).readAsString();
    return _jsonHasServers(text)
        ? _CustomSniffResult(CustomImportKind.mcp, text)
        : const _CustomSniffResult(CustomImportKind.unknown);
  }
  if (lower.endsWith('.zip')) {
    return _sniffZip(path);
  }
  return const _CustomSniffResult(CustomImportKind.unknown);
}

bool _jsonHasServers(String text) {
  try {
    final decoded = jsonDecode(text);
    if (decoded is! Map) return false;
    final raw = decoded['mcpServers'] ?? decoded;
    return raw is Map && raw.isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// Scans zip entry names without extracting to disk. SKILL.md (at any depth,
/// typically root or one folder down) wins; otherwise the first small *.json
/// entry that parses to mcpServers is captured.
Future<_CustomSniffResult> _sniffZip(String path) async {
  final input = InputFileStream(path);
  try {
    final archive = ZipDecoder().decodeStream(input);
    String? mcpJsonText;
    for (final file in archive) {
      if (!file.isFile || file.isSymbolicLink) continue;
      final name = file.name.toLowerCase();
      if (name == 'skill.md' || name.endsWith('/skill.md')) {
        return const _CustomSniffResult(CustomImportKind.skill);
      }
      if (mcpJsonText == null &&
          name.endsWith('.json') &&
          file.size > 0 &&
          file.size < 1024 * 1024) {
        try {
          final text = utf8.decode(file.content as List<int>);
          if (_jsonHasServers(text)) mcpJsonText = text;
        } catch (_) {
          // Not a readable text JSON; skip.
        }
      }
    }
    if (mcpJsonText != null) {
      return _CustomSniffResult(CustomImportKind.mcp, mcpJsonText);
    }
    return const _CustomSniffResult(CustomImportKind.unknown);
  } finally {
    input.closeSync();
  }
}
