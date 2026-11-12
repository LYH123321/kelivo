
import 'dart:io';
import 'dart:typed_data';

import 'character_card_import.dart';

/// A card or world book file found on device storage.
class FoundCardFile {
  final String path;
  final String name;
  final FoundCardKind kind;
  final int sizeBytes;
  const FoundCardFile({
    required this.path,
    required this.name,
    required this.kind,
    required this.sizeBytes,
  });
}

enum FoundCardKind { characterCard, worldBook }

/// Scans common user directories for SillyTavern-style character cards
/// (PNG/CHARX/JSON) and standalone world book JSON files.
class DeviceCardScanner {
  static const List<String> _scanDirs = <String>[
    '/storage/emulated/0/Download',
    '/storage/emulated/0/Documents',
    '/storage/emulated/0/BaiAgent',
    '/storage/emulated/0/st',
  ];

  static const int _maxDepth = 3;
  static const int _maxFileSize = 32 * 1024 * 1024;

  /// Returns files that parse as a character card (PNG/CHARX/JSON)
  /// or a standalone world info JSON.
  static Future<List<FoundCardFile>> scan({
    List<String> roots = _scanDirs,
    int depth = _maxDepth,
  }) async {
    final found = <FoundCardFile>[];
    for (final root in roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      await _walk(dir, depth, found);
    }
    found.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return found;
  }

  static Future<void> _walk(
    Directory dir,
    int depth,
    List<FoundCardFile> found,
  ) async {
    if (depth < 0) return;
    final List<FileSystemEntity> children;
    try {
      children = dir.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    for (final entity in children) {
      try {
        if (entity is Directory) {
          final name = entity.path.split('/').last;
          if (name.startsWith('.')) continue;
          await _walk(entity, depth - 1, found);
        } else if (entity is File) {
          final f = entity;
          final size = f.lengthSync();
          if (size > _maxFileSize || size == 0) continue;
          final lower = f.path.toLowerCase();
          if (lower.endsWith('.png') || lower.endsWith('.charx')) {
            final bytes = f.readAsBytesSync();
            if (parseCharacterCardBytes(bytes, f.path) != null) {
              found.add(FoundCardFile(
                path: f.path,
                name: f.path.split('/').last,
                kind: FoundCardKind.characterCard,
                sizeBytes: size,
              ));
            }
          } else if (lower.endsWith('.json')) {
            final kind = await _classifyJson(f);
            if (kind != null) {
              found.add(FoundCardFile(
                path: f.path,
                name: f.path.split('/').last,
                kind: kind,
                sizeBytes: size,
              ));
            }
          }
        }
      } catch (_) {
        // Permission or read errors on individual entries are non-fatal.
      }
    }
  }

  static Future<FoundCardKind?> _classifyJson(File f) async {
    try {
      final text = await f.readAsString();
      if (text.length > 4 * 1024 * 1024) return null;
      if (!text.contains('"entries"') &&
          !text.contains('"character_book"') &&
          !text.contains('"spec"') &&
          !text.contains('"key"') &&
          !text.contains('"keys"') &&
          !text.contains('"content"')) {
        return null;
      }
      // Cheap structural sniffing; full parse happens at import time.
      if (text.contains('"character_book"') ||
          text.contains('"chara_card_v2"') ||
          text.contains('"chara_card_v3"') ||
          text.contains('"first_mes"')) {
        return FoundCardKind.characterCard;
      }
      if (text.contains('"entries"')) {
        return FoundCardKind.worldBook;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
