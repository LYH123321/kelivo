import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../../core/models/world_book.dart';
import '../../../core/providers/world_book_provider.dart';
import '../../../core/services/character_card_import.dart';
import '../../../core/services/device_card_scanner.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../utils/world_book_import.dart';

/// Scans phone storage for character cards & world books and lets the
/// user import any of them (dsh-Go style picker page).
class DeviceImportPage extends StatefulWidget {
  const DeviceImportPage({super.key});

  @override
  State<DeviceImportPage> createState() => _DeviceImportPageState();
}

class _DeviceImportPageState extends State<DeviceImportPage> {
  bool _scanning = false;
  bool _importing = false;
  List<FoundCardFile> _found = const <FoundCardFile>[];
  final Set<String> _selected = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _rescan());
  }

  Future<void> _rescan() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final items = await DeviceCardScanner.scan();
      if (!mounted) return;
      setState(() {
        _found = items;
        _selected.clear();
      });
    } catch (_) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: 'Scan failed',
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _importSelected() async {
    if (_importing || _selected.isEmpty) return;
    setState(() => _importing = true);
    final wb = context.read<WorldBookProvider>();
    var cards = 0;
    var books = 0;
    try {
      for (final path in _selected) {
        final file = File(path);
        if (!file.existsSync()) continue;
        final Uint8List bytes;
        try {
          bytes = await file.readAsBytes();
        } catch (_) {
          continue;
        }
        final name = path.split('/').last;
        FoundCardKind? kind;
        for (final f in _found) {
          if (f.path == path) {
            kind = f.kind;
            break;
          }
        }
        if (kind == FoundCardKind.characterCard) {
          final parsed = parseCharacterCardBytes(bytes, name);
          if (parsed == null) continue;
          final entries = parsed.lorebookEntries.map((e) {
            final keys = (e['keywords'] as List?)
                    ?.map((k) => k.toString())
                    .toList() ??
                const <String>[];
            final secondary = (e['secondaryKeywords'] as List?)
                    ?.map((k) => k.toString())
                    .toList() ??
                const <String>[];
            final posRaw = (e['position'] ?? '').toString().toLowerCase();
            final pos = posRaw.contains('before')
                ? WorldBookInjectionPosition.beforeSystemPrompt
                : posRaw.contains('depth')
                    ? WorldBookInjectionPosition.atDepth
                    : WorldBookInjectionPosition.afterSystemPrompt;
            return WorldBookEntry(
              id: (e['id'] ?? const Uuid().v4()).toString(),
              name: (e['name'] ?? '').toString(),
              enabled: (e['enabled'] as bool?) ?? true,
              content: (e['content'] ?? '').toString(),
              keywords: keys,
              secondaryKeywords: secondary,
              constantActive: (e['constantActive'] as bool?) ?? false,
              position: pos,
            );
          }).toList();
          final bookName = parsed.card.name.trim().isNotEmpty
              ? parsed.card.name.trim()
              : name.replaceAll(
                  RegExp(r'\.(png|charx|json)$', caseSensitive: false), '');
          final cardBook = WorldBook(
            id: const Uuid().v4(),
            name: bookName,
            description: parsed.card.description,
            entries: entries,
          );
          final normalizedCard = normalizeImportedWorldBook(
            cardBook,
            existingBookIds: wb.books.map((e) => e.id).toSet(),
          );
          await wb.addBook(normalizedCard);
          cards++;
        } else {
          try {
            final text = await file.readAsString();
            final decoded = jsonDecode(text);
            if (decoded is! Map) continue;
            final result = parseWorldBookImport(decoded, fileName: name);
            if (result == null) continue;
            final normalized = normalizeImportedWorldBook(
              result.book,
              existingBookIds: wb.books.map((e) => e.id).toSet(),
            );
            await wb.addBook(normalized);
            books++;
          } catch (_) {
            continue;
          }
        }
      }
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: 'Imported: $cards cards / $books books',
        type: NotificationType.success,
      );
      setState(() => _selected.clear());
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Device Import',
          style: TextStyle(fontWeight: AppFontWeights.heavy),
        ),
        actions: [
          IconButton(
            onPressed: _scanning ? null : _rescan,
            icon: _scanning
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Lucide.RefreshCw, size: 20),
          ),
        ],
      ),
      body: _scanning
          ? const Center(child: CircularProgressIndicator())
          : _found.isEmpty
              ? Center(
                  child: Text(
                    'No cards or world books found',
                    style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
                  itemCount: _found.length,
                  itemBuilder: (context, i) {
                    final item = _found[i];
                    final selected = _selected.contains(item.path);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: IosCardPress(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () {
                          setState(() {
                            if (selected) {
                              _selected.remove(item.path);
                            } else {
                              _selected.add(item.path);
                            }
                          });
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          child: Row(
                            children: [
                              Icon(
                                item.kind == FoundCardKind.characterCard
                                    ? Lucide.User
                                    : Lucide.BookOpen,
                                size: 20,
                                color: cs.onSurface,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: AppFontWeights.medium,
                                        color: cs.onSurface,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      item.path,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: cs.onSurface.withValues(alpha: 0.6),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Icon(
                                selected
                                    ? Lucide.CheckCircle
                                    : Lucide.circleDot,
                                size: 22,
                                color: selected
                                    ? cs.primary
                                    : cs.onSurface.withValues(alpha: 0.35),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
      floatingActionButton: _selected.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _importing ? null : _importSelected,
              icon: _importing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Lucide.Download),
              label: Text('Import (${_selected.length})'),
            ),
    );
  }
}