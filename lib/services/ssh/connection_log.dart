import 'dart:async';

/// One timestamped line of a [ConnectionLog].
class ConnectionLogEntry {
  const ConnectionLogEntry(this.time, this.message, {this.isError = false});

  final DateTime time;
  final String message;
  final bool isError;

  /// Local wall-clock time as `HH:mm:ss.mmm`.
  String get timestamp {
    String two(int value) => value.toString().padLeft(2, '0');
    final millis = time.millisecond.toString().padLeft(3, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}.$millis';
  }

  @override
  String toString() => '$timestamp  ${isError ? 'ERROR ' : ''}$message';
}

/// Step-by-step record of what a session did while connecting.
///
/// Secrets must never be written here: the log is shown on screen and meant
/// to be screenshotted.
class ConnectionLog {
  ConnectionLog({this.maxEntries = 500, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// Oldest entries are dropped beyond this many.
  final int maxEntries;
  final DateTime Function() _clock;

  final _entries = <ConnectionLogEntry>[];
  final _changes = StreamController<List<ConnectionLogEntry>>.broadcast();

  List<ConnectionLogEntry> get entries => List.unmodifiable(_entries);

  /// Emits the full list of entries after every change.
  Stream<List<ConnectionLogEntry>> get changes => _changes.stream;

  void add(String message, {bool isError = false}) {
    if (_changes.isClosed) return;
    _entries.add(ConnectionLogEntry(_clock(), message, isError: isError));
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    _changes.add(entries);
  }

  /// The whole log as plain text, one entry per line.
  String format() => _entries.join('\n');

  void dispose() {
    _changes.close();
  }
}
