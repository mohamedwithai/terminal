import 'dart:io';
import 'dart:typed_data';

/// A scratch file in the app's cache, for a download on its way to being
/// saved. Not on the web, where there is no SFTP.
class LocalTempFile {
  LocalTempFile._(this._file, this._sink);

  final File _file;
  final IOSink _sink;

  static Future<LocalTempFile> create(String name) async {
    final dir = await Directory.systemTemp.createTemp('ssh_download_');
    // Only the last part of the remote name, never a path.
    var safe = name.replaceAll(RegExp(r'[\\/\u0000]'), '_');
    // "." and ".." would name the folder itself or its parent.
    if (safe.isEmpty || safe == '.' || safe == '..') safe = 'file';
    final file = File('${dir.path}/$safe');
    return LocalTempFile._(file, file.openWrite());
  }

  String get path => _file.path;

  Future<void> add(Uint8List chunk) async => _sink.add(chunk);

  Future<void> close() => _sink.close();

  Future<int> length() => _file.length();

  Future<Uint8List> readAll() => _file.readAsBytes();

  /// Removes the file and its folder.
  Future<void> delete() async {
    try {
      await _sink.close();
    } catch (_) {}
    try {
      await _file.parent.delete(recursive: true);
    } catch (_) {}
  }
}
