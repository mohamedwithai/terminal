import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/snippet.dart';
import 'package:ssh_app/services/snippet_store.dart';

/// `main` overrides this with [HiveSnippetStore]. Without the override
/// (widget tests) snippets live in memory.
final snippetStoreProvider = Provider<SnippetStore>((ref) {
  return MemorySnippetStore();
});

final snippetListProvider =
    AsyncNotifierProvider<SnippetListNotifier, List<Snippet>>(
      SnippetListNotifier.new,
    );

class SnippetListNotifier extends AsyncNotifier<List<Snippet>> {
  @override
  Future<List<Snippet>> build() => ref.watch(snippetStoreProvider).list();

  Future<void> save(Snippet snippet) async {
    await ref
        .read(snippetStoreProvider)
        .put(snippet.copyWith(updatedAt: DateTime.now().toUtc()));
    ref.invalidateSelf();
  }

  Future<void> delete(String id) async {
    await ref.read(snippetStoreProvider).delete(id);
    ref.invalidateSelf();
  }

  /// Adds the snippets of an imported file. Returns how many were added.
  Future<int> importAll(List<Snippet> snippets) async {
    final store = ref.read(snippetStoreProvider);
    for (final snippet in snippets) {
      await store.put(snippet);
    }
    ref.invalidateSelf();
    return snippets.length;
  }

  /// Takes [hostId] out of every snippet's on-connect list, when a host is
  /// deleted.
  Future<void> forgetHost(String hostId) async {
    final store = ref.read(snippetStoreProvider);
    for (final snippet in await store.list()) {
      if (snippet.runOnConnect.contains(hostId)) {
        await store.put(
          snippet.copyWith(
            runOnConnect: [
              for (final id in snippet.runOnConnect)
                if (id != hostId) id,
            ],
          ),
        );
      }
    }
    ref.invalidateSelf();
  }
}
