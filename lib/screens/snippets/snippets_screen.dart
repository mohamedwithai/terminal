import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/snippet.dart';
import 'package:ssh_app/providers/snippet_providers.dart';
import 'package:ssh_app/providers/snippet_run_providers.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/screens/snippets/run_progress_screen.dart';
import 'package:ssh_app/screens/snippets/run_sheet.dart';
import 'package:ssh_app/screens/snippets/snippet_edit_screen.dart';
import 'package:ssh_app/theme/tokens.dart';

/// The snippet library: search, tags, what runs automatically, and Run.
class SnippetsScreen extends ConsumerStatefulWidget {
  const SnippetsScreen({super.key});

  @override
  ConsumerState<SnippetsScreen> createState() => _SnippetsScreenState();
}

class _SnippetsScreenState extends ConsumerState<SnippetsScreen> {
  final _search = TextEditingController();
  String? _tag;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _edit([Snippet? snippet]) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SnippetEditScreen(snippet: snippet),
      ),
    );
  }

  Future<void> _run(Snippet snippet) async {
    final hosts = await ref.read(serverListProvider.future);
    if (!mounted) return;
    final request = await showRunSheet(context, snippet: snippet, hosts: hosts);
    if (request == null || !mounted) return;
    final entry = ref
        .read(snippetRunsProvider.notifier)
        .start(snippet: snippet, hosts: request.hosts, values: request.values);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => RunProgressScreen(entry: entry)),
    );
  }

  Future<void> _import() async {
    try {
      final text = await ref.read(keyFilePickerProvider)();
      if (text == null) return;
      final count = await ref
          .read(snippetListProvider.notifier)
          .importAll(SnippetFile.import(text));
      if (mounted) _message('Imported $count snippet${count == 1 ? '' : 's'}.');
    } on FormatException catch (error) {
      if (mounted) _message(error.message);
    } catch (error) {
      if (mounted) _message('Could not import. $error');
    }
  }

  Future<void> _export(List<Snippet> snippets) async {
    if (snippets.isEmpty) {
      _message('Nothing to export yet.');
      return;
    }
    try {
      await ref.read(shareTextProvider)(
        SnippetFile.export(snippets),
        'Snippets',
      );
    } catch (error) {
      if (mounted) _message('Could not open the share sheet. $error');
    }
  }

  Future<void> _delete(Snippet snippet) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete snippet?'),
        content: Text('Delete ${snippet.name}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(snippetListProvider.notifier).delete(snippet.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snippets = ref.watch(snippetListProvider);
    final runs = ref.watch(snippetRunsProvider);
    final hostCount = ref.watch(serverListProvider).asData?.value.length ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Snippets'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (value) {
              if (value == 'import') _import();
              if (value == 'export') {
                _export(snippets.asData?.value ?? const []);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'import', child: Text('Import from file')),
              PopupMenuItem(value: 'export', child: Text('Export all')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'snippets-fab',
        onPressed: _edit,
        icon: const Icon(Icons.add),
        label: const Text('New snippet'),
      ),
      body: snippets.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('$error')),
        data: (items) {
          if (items.isEmpty && runs.isEmpty) {
            return _Empty(onAdd: _edit, onImport: _import);
          }
          final query = _search.text.trim().toLowerCase();
          final tags = {for (final s in items) ...s.tags}.toList()..sort();
          final shown = [
            for (final s in items)
              if ((_tag == null || s.tags.contains(_tag)) &&
                  (query.isEmpty ||
                      s.name.toLowerCase().contains(query) ||
                      s.tags.any((t) => t.toLowerCase().contains(query)) ||
                      s.steps.any(
                        (st) => st.command.toLowerCase().contains(query),
                      )))
                s,
          ];
          final automatic = [
            for (final s in shown)
              if (s.runOnConnect.isNotEmpty) s,
          ];
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 104),
            children: [
              TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: 'Search snippets',
                  prefixIcon: Icon(Icons.search, color: AppColors.muted),
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                ),
              ),
              if (tags.isNotEmpty) ...[
                const SizedBox(height: 12),
                SizedBox(
                  height: AppSizes.minTouch,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final tag in [null, ...tags])
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(tag ?? 'All'),
                            selected: _tag == tag,
                            showCheckmark: false,
                            onSelected: (_) => setState(() => _tag = tag),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              if (runs.isNotEmpty) ...[
                const _Header('Runs'),
                for (final entry in runs) _RunCard(entry: entry),
              ],
              if (automatic.isNotEmpty) ...[
                const _Header('Runs automatically'),
                for (final s in automatic)
                  _SnippetCard(
                    snippet: s,
                    onEdit: () => _edit(s),
                    onRun: () => _run(s),
                    onDelete: () => _delete(s),
                  ),
              ],
              _Header(_tag ?? 'All snippets', count: shown.length),
              if (shown.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    'No snippets match.',
                    textAlign: TextAlign.center,
                  ),
                )
              else
                for (final s in shown)
                  _SnippetCard(
                    snippet: s,
                    onEdit: () => _edit(s),
                    onRun: hostCount == 0 ? null : () => _run(s),
                    onDelete: () => _delete(s),
                  ),
            ],
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title, {this.count});

  final String title;
  final int? count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 10),
      child: Text(
        '${title.toUpperCase()}${count == null ? '' : '  $count'}',
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: AppColors.muted,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _SnippetCard extends StatelessWidget {
  const _SnippetCard({
    required this.snippet,
    required this.onEdit,
    required this.onRun,
    required this.onDelete,
  });

  final Snippet snippet;
  final VoidCallback onEdit;
  final VoidCallback? onRun;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final variables = snippet.allVariables.length;
    final badges = [
      '${snippet.steps.length} step${snippet.steps.length == 1 ? '' : 's'}',
      if (variables > 0) '$variables variable${variables == 1 ? '' : 's'}',
      if (snippet.runOnConnect.isNotEmpty)
        '${snippet.runOnConnect.length} host${snippet.runOnConnect.length == 1 ? '' : 's'}',
      if (snippet.askFirst) 'asks first',
      if (snippet.hasSecret) 'secret',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onEdit,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        snippet.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        snippet.steps.first.command,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: AppFonts.mono,
                          fontSize: 12,
                          color: AppColors.muted,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final badge in badges)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.surfaceRaised,
                                borderRadius: BorderRadius.circular(
                                  AppRadii.key,
                                ),
                              ),
                              child: Text(
                                badge,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: ValueKey('run-${snippet.id}'),
                  tooltip: 'Run',
                  icon: const Icon(
                    Icons.play_arrow_rounded,
                    color: AppColors.accent,
                  ),
                  onPressed: onRun,
                ),
                PopupMenuButton<String>(
                  tooltip: 'Snippet options',
                  onSelected: (value) =>
                      value == 'delete' ? onDelete() : onEdit(),
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        'Delete',
                        style: TextStyle(color: AppColors.error),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RunCard extends ConsumerWidget {
  const _RunCard({required this.entry});

  final RunEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<void>(
      stream: entry.run.changes,
      builder: (context, _) {
        final run = entry.run;
        final done = run.isDone;
        final finished = run.hosts.where((h) => h.status.isFinished).length;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Card(
            child: ListTile(
              leading: done
                  ? Icon(
                      run.succeeded ? Icons.check_circle : Icons.error_outline,
                      color: run.succeeded ? AppColors.accent : AppColors.error,
                    )
                  : const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
              title: Text(entry.snippetName),
              subtitle: Text(
                done
                    ? (run.succeeded ? 'Done' : '${run.failedCount} failed')
                    : '$finished of ${run.hosts.length} hosts finished',
              ),
              trailing: done
                  ? IconButton(
                      tooltip: 'Dismiss',
                      icon: const Icon(Icons.close),
                      onPressed: () =>
                          ref.read(snippetRunsProvider.notifier).remove(entry),
                    )
                  : const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => RunProgressScreen(entry: entry),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onAdd, required this.onImport});

  final VoidCallback onAdd;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadii.card),
                border: Border.all(color: AppColors.border),
              ),
              child: const Icon(Icons.code, color: AppColors.accent, size: 30),
            ),
            const SizedBox(height: 16),
            Text('No snippets yet', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Save the commands you type often, then run them with a tap, '
              'on one host or many.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('New snippet'),
            ),
            TextButton(
              onPressed: onImport,
              child: const Text('Import from file'),
            ),
          ],
        ),
      ),
    );
  }
}
