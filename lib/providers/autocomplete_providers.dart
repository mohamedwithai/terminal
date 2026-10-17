import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/services/autocomplete/history.dart';

/// `main` overrides this with [HiveHistoryStore]; without it (widget tests)
/// history lives in memory.
final historyStoreProvider = Provider<HistoryStore>((ref) {
  return MemoryHistoryStore();
});

/// Per-host command history, for suggestions.
final commandHistoryProvider = Provider<CommandHistory>((ref) {
  return CommandHistory(ref.watch(historyStoreProvider));
});
