import 'dart:convert';

import 'package:hive/hive.dart';
import 'package:ssh_app/models/snippet.dart';

/// Saved snippets. Never holds secret values: a secret variable has none.
abstract interface class SnippetStore {
  Future<List<Snippet>> list();

  Future<void> put(Snippet snippet);

  Future<void> delete(String id);
}

/// [SnippetStore] in the Hive box `snippets`, one JSON string per snippet.
class HiveSnippetStore implements SnippetStore {
  HiveSnippetStore(this._box);

  static const boxName = 'snippets';

  final Box<String> _box;

  static Future<HiveSnippetStore> open() async {
    return HiveSnippetStore(await Hive.openBox<String>(boxName));
  }

  @override
  Future<List<Snippet>> list() async {
    final snippets = <Snippet>[];
    for (final raw in _box.values) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          snippets.add(Snippet.fromJson(Map<String, dynamic>.from(decoded)));
        }
      } on FormatException {
        // A damaged record is skipped rather than hiding all the others.
      }
    }
    snippets.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return snippets;
  }

  @override
  Future<void> put(Snippet snippet) {
    return _box.put(snippet.id, jsonEncode(snippet.toJson()));
  }

  @override
  Future<void> delete(String id) => _box.delete(id);
}

/// [SnippetStore] that forgets everything when the app closes.
class MemorySnippetStore implements SnippetStore {
  final Map<String, String> _items = {};

  @override
  Future<List<Snippet>> list() async {
    final all = [
      for (final raw in _items.values)
        Snippet.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map)),
    ];
    all.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return all;
  }

  @override
  Future<void> put(Snippet snippet) async {
    _items[snippet.id] = jsonEncode(snippet.toJson());
  }

  @override
  Future<void> delete(String id) async {
    _items.remove(id);
  }
}
