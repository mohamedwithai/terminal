import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/snippet.dart';
import 'package:ssh_app/providers/snippet_providers.dart';
import 'package:ssh_app/theme/tokens.dart';

/// Picks a snippet by name from a searchable list. Returns null if closed.
Future<Snippet?> showSnippetPicker(BuildContext context) {
  return showModalBottomSheet<Snippet>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const SnippetPickerSheet(),
  );
}

class SnippetPickerSheet extends ConsumerStatefulWidget {
  const SnippetPickerSheet({super.key});

  @override
  ConsumerState<SnippetPickerSheet> createState() => _SnippetPickerSheetState();
}

class _SnippetPickerSheetState extends ConsumerState<SnippetPickerSheet> {
  var _query = '';

  @override
  Widget build(BuildContext context) {
    final snippets = ref.watch(snippetListProvider).asData?.value ?? const [];
    final query = _query.trim().toLowerCase();
    final shown = [
      for (final s in snippets)
        if (query.isEmpty ||
            s.name.toLowerCase().contains(query) ||
            s.tags.any((t) => t.toLowerCase().contains(query)) ||
            s.steps.any((step) => step.command.toLowerCase().contains(query)))
          s,
    ];
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: insets),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                autofocus: true,
                onChanged: (v) => setState(() => _query = v),
                decoration: const InputDecoration(
                  hintText: 'Search snippets',
                  prefixIcon: Icon(Icons.search, color: AppColors.muted),
                ),
              ),
            ),
            Expanded(
              child: snippets.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No snippets yet. Create one in the Snippets tab.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : shown.isEmpty
                  ? const Center(child: Text('No snippets match.'))
                  : ListView(
                      children: [
                        for (final snippet in shown)
                          ListTile(
                            key: ValueKey('pick-${snippet.id}'),
                            leading: const Icon(
                              Icons.code,
                              color: AppColors.accent,
                            ),
                            title: Text(snippet.name),
                            subtitle: Text(
                              snippet.steps.first.command,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: AppFonts.mono,
                                fontSize: 12,
                              ),
                            ),
                            trailing: Text(
                              '${snippet.steps.length} step${snippet.steps.length == 1 ? '' : 's'}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            onTap: () => Navigator.of(context).pop(snippet),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
