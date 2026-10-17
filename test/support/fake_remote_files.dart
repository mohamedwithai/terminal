import 'dart:async';
import 'dart:typed_data';

import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/services/sftp/remote_file_system.dart';
import 'package:ssh_app/services/sftp/sftp_opener.dart';
import 'package:ssh_app/services/ssh/ssh_connection_session.dart';

/// An in-memory remote file system.
class FakeRemoteFiles implements RemoteFileSystem {
  FakeRemoteFiles({this.homeDirectory = '/home/ada'}) {
    folders.addAll({'/', '/home', homeDirectory});
  }

  final String homeDirectory;
  final folders = <String>{};
  final files = <String, Uint8List>{};
  final modified = <String, DateTime>{};
  final calls = <String>[];
  var closed = false;

  /// Paths that fail with a message when touched.
  final failures = <String, String>{};

  /// Holds a download or upload after its first chunk until completed.
  Completer<void>? hold;

  void addFile(String path, List<int> bytes, {DateTime? at}) {
    files[path] = Uint8List.fromList(bytes);
    if (at != null) modified[path] = at;
    var dir = parentRemote(path);
    while (true) {
      folders.add(dir);
      if (dir == '/') break;
      dir = parentRemote(dir);
    }
  }

  void addFolder(String path) => folders.add(path);

  void _check(String path) {
    final message = failures[path];
    if (message != null) throw RemoteFileException(message);
  }

  @override
  Future<String> home() async => homeDirectory;

  @override
  Future<List<RemoteEntry>> list(String directory) async {
    calls.add('list $directory');
    _check(directory);
    if (!folders.contains(directory)) {
      throw const RemoteFileException('That file or folder no longer exists.');
    }
    final prefix = directory == '/' ? '/' : '$directory/';
    final names = <String, RemoteEntry>{};
    for (final folder in folders) {
      if (folder != directory && folder.startsWith(prefix)) {
        final rest = folder.substring(prefix.length);
        if (!rest.contains('/')) {
          names[rest] = RemoteEntry(
            name: rest,
            isDirectory: true,
            modified: modified[folder],
          );
        }
      }
    }
    for (final entry in files.entries) {
      if (entry.key.startsWith(prefix)) {
        final rest = entry.key.substring(prefix.length);
        if (!rest.contains('/')) {
          names[rest] = RemoteEntry(
            name: rest,
            isDirectory: false,
            size: entry.value.length,
            modified: modified[entry.key],
            permissions: 'rw-r--r--',
          );
        }
      }
    }
    return names.values.toList();
  }

  @override
  Future<void> createFolder(String path) async {
    calls.add('mkdir $path');
    _check(path);
    folders.add(path);
  }

  @override
  Future<void> rename(String from, String to) async {
    calls.add('rename $from $to');
    _check(from);
    if (files.containsKey(from)) {
      files[to] = files.remove(from)!;
    } else if (folders.contains(from)) {
      folders.remove(from);
      folders.add(to);
      for (final f in folders.toList()) {
        if (f.startsWith('$from/')) {
          folders
            ..remove(f)
            ..add('$to${f.substring(from.length)}');
        }
      }
      for (final f in files.keys.toList()) {
        if (f.startsWith('$from/')) {
          files['$to${f.substring(from.length)}'] = files.remove(f)!;
        }
      }
    }
  }

  @override
  Future<void> delete(String path, {required bool isDirectory}) async {
    calls.add('delete $path');
    _check(path);
    if (isDirectory) {
      folders.removeWhere((f) => f == path || f.startsWith('$path/'));
      files.removeWhere((f, _) => f.startsWith('$path/'));
    } else {
      files.remove(path);
    }
  }

  @override
  Future<int> countEntries(String directory) async {
    final prefix = '$directory/';
    return folders.where((f) => f.startsWith(prefix)).length +
        files.keys.where((f) => f.startsWith(prefix)).length;
  }

  @override
  Stream<Uint8List> download(
    String path, {
    TransferProgress? onProgress,
    TransferCancel? cancel,
  }) async* {
    calls.add('download $path');
    _check(path);
    final data = files[path];
    if (data == null) {
      throw const RemoteFileException('That file or folder no longer exists.');
    }
    var sent = 0;
    for (var i = 0; i < data.length; i += 4) {
      if (cancel?.isCancelled ?? false) throw const TransferCancelled();
      final chunk = data.sublist(i, i + 4 > data.length ? data.length : i + 4);
      sent += chunk.length;
      onProgress?.call(sent, data.length);
      yield chunk;
      final gate = hold;
      if (gate != null) {
        await gate.future;
      }
    }
  }

  @override
  Future<void> upload(
    String path,
    Stream<Uint8List> data, {
    int? total,
    TransferProgress? onProgress,
    TransferCancel? cancel,
  }) async {
    calls.add('upload $path');
    _check(path);
    final received = BytesBuilder();
    await for (final chunk in data) {
      if (cancel?.isCancelled ?? false) throw const TransferCancelled();
      received.add(chunk);
      onProgress?.call(received.length, total);
      final gate = hold;
      if (gate != null) {
        await gate.future;
      }
    }
    if (cancel?.isCancelled ?? false) throw const TransferCancelled();
    addFile(path, received.takeBytes());
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// An opener that hands out [files] and records how it was asked.
class FakeSftpOpener {
  FakeSftpOpener(this.files);

  final FakeRemoteFiles files;
  final opened = <({String serverId, bool reused})>[];
  var released = 0;
  RemoteFileException? failWith;

  Future<SftpHandle> call(
    ServerConfig server, {
    SSHConnectionSession? reuse,
  }) async {
    opened.add((serverId: server.id, reused: reuse != null));
    final error = failWith;
    if (error != null) throw error;
    return SftpHandle(files, () async => released++);
  }
}
