import 'dart:convert';

import 'package:hive/hive.dart';

/// Words that make a command line too sensitive to remember.
const _sensitive = [
  'password',
  'passwd',
  'passphrase',
  'token',
  'secret',
  'key=',
  'apikey',
  'api_key',
  'authorization',
];

/// Whether [command] may be kept in the history.
///
/// Lines that start with a space are left out, as shells do; so is anything
/// that looks like it carries a password, token, secret or key.
bool isRecordable(String command) {
  if (command.isEmpty || command.startsWith(' ') || command.trim().isEmpty) {
    return false;
  }
  final lower = command.toLowerCase();
  if (_sensitive.any(lower.contains)) return false;
  return command.length <= 500;
}

class HistoryEntry {
  const HistoryEntry({
    required this.command,
    required this.count,
    required this.lastUsed,
  });

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
    command: json['c'] as String,
    count: (json['n'] as num).toInt(),
    lastUsed: DateTime.fromMillisecondsSinceEpoch(
      (json['t'] as num).toInt(),
      isUtc: true,
    ),
  );

  final String command;
  final int count;
  final DateTime lastUsed;

  Map<String, dynamic> toJson() => {
    'c': command,
    'n': count,
    't': lastUsed.toUtc().millisecondsSinceEpoch,
  };
}

/// Where per-host history is kept on this device.
abstract interface class HistoryStore {
  List<HistoryEntry> read(String hostId);

  Future<void> write(String hostId, List<HistoryEntry> entries);

  Future<void> clear(String hostId);

  /// Hosts that have any history.
  List<String> hosts();
}

class HiveHistoryStore implements HistoryStore {
  HiveHistoryStore(this._box);

  static const boxName = 'command_history';

  final Box<String> _box;

  static Future<HiveHistoryStore> open() async {
    return HiveHistoryStore(await Hive.openBox<String>(boxName));
  }

  @override
  List<HistoryEntry> read(String hostId) {
    final raw = _box.get(hostId);
    if (raw == null) return const [];
    try {
      return [
        for (final item in jsonDecode(raw) as List)
          HistoryEntry.fromJson(Map<String, dynamic>.from(item as Map)),
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> write(String hostId, List<HistoryEntry> entries) {
    return _box.put(hostId, jsonEncode([for (final e in entries) e.toJson()]));
  }

  @override
  Future<void> clear(String hostId) => _box.delete(hostId);

  @override
  List<String> hosts() => [for (final key in _box.keys) key as String];
}

class MemoryHistoryStore implements HistoryStore {
  final Map<String, List<HistoryEntry>> data = {};

  @override
  List<HistoryEntry> read(String hostId) => data[hostId] ?? const [];

  @override
  Future<void> write(String hostId, List<HistoryEntry> entries) async {
    data[hostId] = entries;
  }

  @override
  Future<void> clear(String hostId) async {
    data.remove(hostId);
  }

  @override
  List<String> hosts() => data.keys.toList();
}

/// Per-host command history: what was run, how often and when.
class CommandHistory {
  CommandHistory(this._store, {this.limit = 2000, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final HistoryStore _store;

  /// Most commands kept per host. The least recently used go first.
  final int limit;
  final DateTime Function() _clock;
  final Map<String, List<HistoryEntry>> _cache = {};

  List<HistoryEntry> entries(String hostId) {
    return _cache.putIfAbsent(hostId, () => [..._store.read(hostId)]);
  }

  int count(String hostId) => entries(hostId).length;

  /// Remembers that [command] was run on [hostId]. Returns whether it was
  /// kept (see [isRecordable]).
  Future<bool> record(String hostId, String command) async {
    final trimmed = command.trimRight();
    if (!isRecordable(trimmed)) return false;
    final list = entries(hostId);
    final now = _clock().toUtc();
    final index = list.indexWhere((e) => e.command == trimmed);
    if (index >= 0) {
      final old = list[index];
      list[index] = HistoryEntry(
        command: trimmed,
        count: old.count + 1,
        lastUsed: now,
      );
    } else {
      list.add(HistoryEntry(command: trimmed, count: 1, lastUsed: now));
      if (list.length > limit) {
        list.sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
        list.removeRange(limit, list.length);
      }
    }
    await _store.write(hostId, list);
    return true;
  }

  Future<void> clear(String hostId) async {
    _cache.remove(hostId);
    await _store.clear(hostId);
  }

  /// Hosts with history, for the settings screen.
  List<String> hosts() => _store.hosts();
}
