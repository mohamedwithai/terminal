import 'dart:typed_data';

/// The web has no SFTP, so no local files.
class LocalTempFile {
  LocalTempFile._();

  static Future<LocalTempFile> create(String name) {
    throw UnsupportedError('Downloads are not supported on the web.');
  }

  String get path => throw UnsupportedError('No local files on the web.');

  Future<void> add(Uint8List chunk) async {}

  Future<void> close() async {}

  Future<int> length() async => 0;

  Future<Uint8List> readAll() async => Uint8List(0);

  Future<void> delete() async {}
}
