import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:ssh_app/services/sftp/remote_file_system.dart';

/// [RemoteFileSystem] over an SFTP channel of an open SSH connection.
///
/// Closing it closes the SFTP channel only, never the SSH connection, which
/// may be a terminal's.
class SftpFileSystem implements RemoteFileSystem {
  SftpFileSystem(this._sftp);

  final SftpClient _sftp;

  @override
  Future<String> home() => _guard(() => _sftp.absolute('.'));

  @override
  Future<List<RemoteEntry>> list(String directory) {
    return _guard(() async {
      final names = await _sftp.listdir(directory);
      final entries = <RemoteEntry>[];
      for (final name in names) {
        if (name.filename == '.' || name.filename == '..') continue;
        var attr = name.attr;
        var isDirectory = attr.isDirectory;
        final isLink = attr.isSymbolicLink;
        if (isLink) {
          // What the link points at decides whether it opens as a folder.
          try {
            attr = await _sftp.stat(joinRemote(directory, name.filename));
            isDirectory = attr.isDirectory;
          } catch (_) {
            isDirectory = false;
          }
        }
        final modified = attr.modifyTime;
        entries.add(
          RemoteEntry(
            name: name.filename,
            isDirectory: isDirectory,
            isLink: isLink,
            size: isDirectory ? null : attr.size,
            modified: modified == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    modified * 1000,
                    isUtc: true,
                  ),
            permissions: _permissions(attr.mode),
          ),
        );
      }
      return entries;
    });
  }

  static String? _permissions(SftpFileMode? mode) {
    if (mode == null) return null;
    String bit(bool on, String c) => on ? c : '-';
    return '${bit(mode.userRead, 'r')}${bit(mode.userWrite, 'w')}'
        '${bit(mode.userExecute, 'x')}${bit(mode.groupRead, 'r')}'
        '${bit(mode.groupWrite, 'w')}${bit(mode.groupExecute, 'x')}'
        '${bit(mode.otherRead, 'r')}${bit(mode.otherWrite, 'w')}'
        '${bit(mode.otherExecute, 'x')}';
  }

  @override
  Future<void> createFolder(String path) => _guard(() => _sftp.mkdir(path));

  @override
  Future<void> rename(String from, String to) {
    return _guard(() => _sftp.rename(from, to));
  }

  @override
  Future<void> delete(String path, {required bool isDirectory}) {
    return _guard(() => _delete(path, isDirectory));
  }

  Future<void> _delete(String path, bool isDirectory) async {
    if (!isDirectory) {
      await _sftp.remove(path);
      return;
    }
    for (final child in await _sftp.listdir(path)) {
      if (child.filename == '.' || child.filename == '..') continue;
      final childPath = joinRemote(path, child.filename);
      // A link is removed as a link, never followed into its target.
      await _delete(
        childPath,
        child.attr.isDirectory && !child.attr.isSymbolicLink,
      );
    }
    await _sftp.rmdir(path);
  }

  @override
  Future<int> countEntries(String directory) {
    return _guard(() async {
      var count = 0;
      for (final child in await _sftp.listdir(directory)) {
        if (child.filename == '.' || child.filename == '..') continue;
        count++;
        if (child.attr.isDirectory && !child.attr.isSymbolicLink) {
          count += await countEntries(joinRemote(directory, child.filename));
        }
      }
      return count;
    });
  }

  @override
  Stream<Uint8List> download(
    String path, {
    TransferProgress? onProgress,
    TransferCancel? cancel,
  }) async* {
    final SftpFile file;
    int? total;
    try {
      file = await _sftp.open(path);
      total = (await file.stat()).size;
    } on SftpError catch (error) {
      throw RemoteFileException(_message(error));
    }
    try {
      await for (final chunk in file.read(
        onProgress: (bytes) => onProgress?.call(bytes, total),
      )) {
        if (cancel?.isCancelled ?? false) throw const TransferCancelled();
        yield chunk;
      }
    } on SftpError catch (error) {
      throw RemoteFileException(_message(error));
    } finally {
      await file.close();
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
    final SftpFile file;
    try {
      file = await _sftp.open(
        path,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );
    } on SftpError catch (error) {
      throw RemoteFileException(_message(error));
    }
    var cancelled = false;
    try {
      final writer = file.write(
        data,
        onProgress: (bytes) => onProgress?.call(bytes, total),
      );
      cancel?.onCancel(() {
        cancelled = true;
        unawaited(writer.abort());
      });
      await writer.done;
    } on SftpError catch (error) {
      throw RemoteFileException(_message(error));
    } finally {
      await file.close();
    }
    if (cancelled || (cancel?.isCancelled ?? false)) {
      // Do not leave half a file behind.
      try {
        await _sftp.remove(path);
      } catch (_) {}
      throw const TransferCancelled();
    }
  }

  @override
  Future<void> close() async {
    try {
      await _sftp.close();
    } catch (_) {
      // Already closed with the connection.
    }
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on SftpError catch (error) {
      throw RemoteFileException(_message(error));
    }
  }

  static String _message(SftpError error) {
    if (error is SftpStatusError) {
      return switch (error.code) {
        2 => 'That file or folder no longer exists.',
        3 => 'Permission denied.',
        _ =>
          error.message.isEmpty
              ? 'The server refused the request.'
              : error.message,
      };
    }
    return error.message;
  }
}
