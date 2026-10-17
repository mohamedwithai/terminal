import 'dart:async';
import 'dart:typed_data';

/// One entry of a remote directory.
class RemoteEntry {
  const RemoteEntry({
    required this.name,
    required this.isDirectory,
    this.size,
    this.modified,
    this.isLink = false,
    this.permissions,
  });

  final String name;
  final bool isDirectory;

  /// Bytes, for files.
  final int? size;
  final DateTime? modified;

  /// A symbolic link. [isDirectory] says what it points at, when known.
  final bool isLink;

  /// Like `rwxr-xr-x`, when the server says.
  final String? permissions;
}

/// A transfer in progress: [bytes] so far out of [total] (null if unknown).
typedef TransferProgress = void Function(int bytes, int? total);

/// A transfer that can be stopped.
class TransferCancel {
  var _cancelled = false;
  final _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in [..._listeners]) {
      listener();
    }
  }

  /// Calls [listener] when cancelled (at once if it already was).
  void onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }
}

/// A transfer was stopped by the user.
class TransferCancelled implements Exception {
  const TransferCancelled();

  @override
  String toString() => 'Cancelled';
}

/// A remote file operation failed; [message] is safe to show.
class RemoteFileException implements Exception {
  const RemoteFileException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The remote files, as the browser sees them. `SftpFileSystem` is the real
/// one; tests use a fake.
abstract interface class RemoteFileSystem {
  /// The directory a session starts in.
  Future<String> home();

  Future<List<RemoteEntry>> list(String directory);

  Future<void> createFolder(String path);

  Future<void> rename(String from, String to);

  /// Deletes a file, or a folder and everything in it.
  Future<void> delete(String path, {required bool isDirectory});

  /// How many entries a folder holds in all, for the delete warning.
  Future<int> countEntries(String directory);

  /// Reads [path] in chunks. Stops with [TransferCancelled] when [cancel]
  /// fires.
  Stream<Uint8List> download(
    String path, {
    TransferProgress? onProgress,
    TransferCancel? cancel,
  });

  /// Writes [data] to [path], replacing what is there.
  Future<void> upload(
    String path,
    Stream<Uint8List> data, {
    int? total,
    TransferProgress? onProgress,
    TransferCancel? cancel,
  });

  Future<void> close();
}

/// Joins a remote directory and a name with exactly one `/`.
String joinRemote(String directory, String name) {
  if (directory.isEmpty) return name;
  return directory.endsWith('/') ? '$directory$name' : '$directory/$name';
}

/// The directory that holds [path]; `/` for a top-level entry.
String parentRemote(String path) {
  if (path == '/' || path.isEmpty) return '/';
  final trimmed = path.length > 1 && path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;
  final slash = trimmed.lastIndexOf('/');
  if (slash <= 0) return '/';
  return trimmed.substring(0, slash);
}

/// The last part of [path].
String baseName(String path) {
  final trimmed = path.length > 1 && path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;
  return trimmed.substring(trimmed.lastIndexOf('/') + 1);
}

/// The parts of a path to show as a trail: `/` then each folder with the
/// path to it.
List<({String name, String path})> breadcrumbs(String path) {
  final crumbs = [(name: '/', path: '/')];
  var current = '';
  for (final part in path.split('/')) {
    if (part.isEmpty) continue;
    current = '$current/$part';
    crumbs.add((name: part, path: current));
  }
  return crumbs;
}

/// How files can be ordered.
enum SortField {
  name('Name'),
  size('Size'),
  modified('Modified');

  const SortField(this.label);

  final String label;
}

/// Orders [entries]: folders first, then by [field]. [descending] flips the
/// order within each group.
List<RemoteEntry> sortEntries(
  List<RemoteEntry> entries,
  SortField field, {
  bool descending = false,
}) {
  int compare(RemoteEntry a, RemoteEntry b) {
    final result = switch (field) {
      SortField.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      SortField.size => (a.size ?? 0).compareTo(b.size ?? 0),
      SortField.modified =>
        (a.modified ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(
          b.modified ?? DateTime.fromMillisecondsSinceEpoch(0),
        ),
    };
    if (result != 0) return descending ? -result : result;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  final folders = [
    for (final e in entries)
      if (e.isDirectory) e,
  ]..sort(compare);
  final files = [
    for (final e in entries)
      if (!e.isDirectory) e,
  ]..sort(compare);
  return [...folders, ...files];
}

/// `1.4 MB`, `820 B`.
String formatSize(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = unit == 0 || value >= 100
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

/// Why a name cannot be used for a file or folder, or null if it can.
String? nameProblem(String name) {
  if (name.trim().isEmpty) return 'Enter a name.';
  if (name.contains('/')) return 'A name cannot contain "/".';
  if (name == '.' || name == '..') return 'Choose another name.';
  if (name.contains('\u0000')) return 'That name is not allowed.';
  return null;
}
