part of 'assistant_settings_edit_page.dart';

/// Whole-book world book binding tab for an assistant (dsh-Go style).
class _AssistantWorldBookTab extends StatefulWidget {
  const _AssistantWorldBookTab({required this.assistantId});
  final String assistantId;

  @override
  State<_AssistantWorldBookTab> createState() => _AssistantWorldBookTabState();
}

class _AssistantWorldBookTabState extends State<_AssistantWorldBookTab> {
  bool _importing = false;

  Future<void> _importFromFile() async {
    final l10n = AppLocalizations.of(context)!;
    final wb = context.read<WorldBookProvider>();
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: const ['json', 'png', 'charx'],
        withData: false,
      );
    } catch (_) {
      return;
    }
    if (result == null || result.files.isEmpty) return;
    setState(() => _importing = true);
    var imported = 0;
    try {
      for (final file in result.files) {
        try {
          final lower = file.name.toLowerCase();
          WorldBook? book;
          if (lower.endsWith('.png') || lower.endsWith('.charx')) {
            Uint8List? bytes = file.bytes;
            if ((bytes == null || bytes.isEmpty) &&
                file.path != null &&
                file.path!.isNotEmpty) {
              try {
                bytes = await File(file.path!).readAsBytes();
              } catch (_) {}
            }
            if (bytes != null && bytes.isNotEmpty) {
              final parsed = parseCharacterCardBytes(bytes, file.name);
              if (parsed != null && parsed.lorebookEntries.isNotEmpty) {
                final entries = parsed.lorebookEntries.map((e) {
                  final keys = (e['keywords'] as List?)
                          ?.map((k) => k.toString())
                          .toList() ??
                      const <String>[];
                  final rawSecondary =
                      e['secondary_keys'] ?? e['secondaryKeywords'];
                  final secondary = (rawSecondary is List)
                      ? rawSecondary
                          .map((k) => k.toString().trim())
                          .where((k) => k.isNotEmpty)
                          .toList(growable: false)
                      : const <String>[];
                  final posRaw = (e['position'] ?? '').toString().toLowerCase();
                  return WorldBookEntry(
                    id: (e['id'] ?? const Uuid().v4()).toString(),
                    name: (e['name'] ?? '').toString(),
                    enabled: (e['enabled'] as bool?) ?? true,
                    content: (e['content'] ?? '').toString(),
                    keywords: keys,
                    secondaryKeywords: secondary,
                    selectiveLogic:
                        (e['selectiveLogic'] as num?)?.toInt() ?? 0,
                    useRegex: e['use_regex'] == true,
                    constantActive:
                        (e['constantActive'] as bool?) ?? false,
                    position: posRaw.contains('before')
                        ? WorldBookInjectionPosition.beforeSystemPrompt
                        : posRaw.contains('depth')
                            ? WorldBookInjectionPosition.atDepth
                            : WorldBookInjectionPosition.afterSystemPrompt,
                  );
                }).toList();
                book = WorldBook(
                  id: const Uuid().v4(),
                  name: parsed.card.name.trim().isNotEmpty
                      ? parsed.card.name.trim()
                      : file.name.replaceFirst(
                          RegExp(r'\.(png|charx|json)$',
                              caseSensitive: false),
                          ''),
                  description: parsed.card.description,
                  entries: entries,
                );
              }
            }
          } else if (file.path != null) {
            final text = await File(file.path!).readAsString();
            final decoded = jsonDecode(text);
            if (decoded is Map) {
              final result = parseWorldBookImport(decoded,
                  fileName: file.name);
              if (result != null) book = result.book;
            }
          }
          if (book != null) {
            final normalized = normalizeImportedWorldBook(book,
                existingBookIds: wb.books.map((e) => e.id).toSet());
            await wb.addBook(normalized);
            imported++;
          }
        } catch (_) {
          continue;
        }
      }
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: imported > 0
            ? '${l10n.worldBookTitle}: +$imported'
            : l10n.assistantEditSystemPromptImportEmpty,
        type:
            imported > 0 ? NotificationType.success : NotificationType.warning,
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final wb = context.watch<WorldBookProvider>();
    final activeIds = wb.activeBookIdsFor(widget.assistantId).toSet();
    final books = wb.books;
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: () => wb.initialize(),
          child: books.isEmpty
              ? ListView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 64, bottom: 24),
                      child: Center(
                        child: Text(
                          AppLocalizations.of(context)!.worldBookEmptyMessage,
                          style: TextStyle(
                            color: cs.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                  itemCount: books.length,
                  itemBuilder: (context, index) {
                    final book = books[index];
                    final selected = activeIds.contains(book.id);
                    final disabled = !book.enabled;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: IosCardPress(
                        onTap: disabled
                            ? null
                            : () async {
                                Haptics.light();
                                await wb.toggleActiveBookId(book.id,
                                    assistantId: widget.assistantId);
                              },
                        borderRadius: BorderRadius.circular(14),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        child: Row(
                          children: [
                            Icon(
                              Lucide.BookOpen,
                              size: 20,
                              color: selected
                                  ? cs.primary
                                  : cs.onSurfaceVariant,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    book.name.trim().isEmpty
                                        ? AppLocalizations.of(context)!
                                            .worldBookUnnamed
                                        : book.name.trim(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight:
                                          AppFontWeights.semibold,
                                      color: disabled
                                          ? cs.onSurface
                                              .withValues(alpha: 0.4)
                                          : cs.onSurface,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '${AppLocalizations.of(context)!.worldBookEnabledCount(book.enabledEntryCount, book.entries.length)}'
                                    '${book.description.trim().isNotEmpty ? ' · ${book.description.trim()}' : ''}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              selected
                                  ? Lucide.CheckCircle
                                  : Lucide.CircleStop,
                              size: 22,
                              color: selected
                                  ? cs.primary
                                  : cs.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 24,
          child: Center(
            child: IosCardPress(
              onTap: _importing ? null : _importFromFile,
              borderRadius: BorderRadius.circular(24),
              baseColor: cs.primary.withValues(alpha: 0.14),
              pressedBlendStrength: 0.18,
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _importing
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: cs.primary),
                        )
                      : Icon(Lucide.FolderOpen,
                          size: 18, color: cs.primary),
                  const SizedBox(width: 8),
                  Text(
                    AppLocalizations.of(context)!.worldBookTitle,
                    style: TextStyle(
                      color: cs.primary,
                      fontWeight: AppFontWeights.emphasis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
