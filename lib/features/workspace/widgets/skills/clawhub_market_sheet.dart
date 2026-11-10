import 'dart:io';

import 'package:Kelivo/core/services/skills/clawhub_market.dart';
import 'package:Kelivo/core/services/skills/skills_service.dart';
import 'package:Kelivo/shared/widgets/ios_tactile.dart';
import 'package:Kelivo/shared/widgets/snackbar.dart';
import 'package:flutter/material.dart';
import 'package:Kelivo/icons/lucide_adapter.dart';
import 'package:provider/provider.dart';

/// Bottom-sheet marketplace backed by the public ClawHub registry.
/// Search -> pick -> one-tap install via the existing skills import zip path.
class ClawHubMarketSheet extends StatefulWidget {
  const ClawHubMarketSheet({super.key});

  static Future<void> show(BuildContext context) {
    if (MediaQuery.of(context).size.width >= 700) {
      return showDialog(
        context: context,
        builder: (_) => const Dialog(
          child: SizedBox(width: 560, height: 620, child: ClawHubMarketSheet()),
        ),
      );
    }
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        minChildSize: 0.5,
        builder: (_, __) => const ClawHubMarketSheet(),
      ),
    );
  }

  @override
  State<ClawHubMarketSheet> createState() => _ClawHubMarketSheetState();
}

class _ClawHubMarketSheetState extends State<ClawHubMarketSheet> {
  final _client = ClawHubClient();
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  List<ClawHubPackage>? _results;
  String? _error;
  bool _busy = false;
  String? _installing;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    _client.dispose();
    super.dispose();
  }

  Future<void> _search([String? query]) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final results = await _client.search(query ?? _controller.text.trim());
      if (!mounted) return;
      setState(() {
        _results = results;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  Future<void> _install(ClawHubPackage pkg) async {
    if (_installing != null) return;
    setState(() => _installing = pkg.reference);
    try {
      final zip = await _client.downloadZip(pkg.ownerHandle, pkg.name);
      if (!mounted) return;
      await context.read<SkillsService>().importFromFile(zip.path);
      try {
        await zip.parent.delete(recursive: true);
      } catch (_) {}
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: 'Installed: ${pkg.reference}',
        type: NotificationType.success,
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _installing = null);
      showAppSnackBar(
        context,
        message: 'Install failed: $e',
        type: NotificationType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      hintText: 'Search ClawHub plugins...',
                      prefixIcon: const Icon(Lucide.Search, size: 18),
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IosIconButton(
                  icon: Lucide.Search,
                  size: 20,
                  minSize: 44,
                  semanticLabel: 'search',
                  onTap: () => _search(),
                ),
              ],
            ),
          ),
          Expanded(child: _buildBody(cs)),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    if (_busy && _results == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center,
              style: TextStyle(color: cs.error)),
        ),
      );
    }
    final results = _results ?? const <ClawHubPackage>[];
    if (results.isEmpty) {
      return const Center(child: Text('No results'));
    }
    return Scrollbar(
      controller: _scroll,
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: results.length,
        itemBuilder: (context, index) {
          final pkg = results[index];
          final installing = _installing == pkg.reference;
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            elevation: 0,
            color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
            child: ListTile(
              leading: Icon(
                pkg.featured ? Lucide.Compass : Lucide.Package,
                color: cs.primary,
              ),
              title: Text(
                pkg.reference,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                pkg.summary.isEmpty
                    ? '${pkg.downloads} downloads'
                    : pkg.summary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: installing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IosIconButton(
                      icon: Lucide.Download,
                      size: 20,
                      minSize: 44,
                      semanticLabel: 'install ${pkg.reference}',
                      onTap: () => _install(pkg),
                    ),
            ),
          );
        },
      ),
    );
  }
}
