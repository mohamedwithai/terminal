import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/providers/sftp_providers.dart';
import 'package:ssh_app/services/sftp/local_temp_file.dart';
import 'package:ssh_app/services/sftp/remote_file_system.dart';
import 'package:ssh_app/services/sftp/sftp_opener.dart';
import 'package:ssh_app/services/ssh/ssh_connection_session.dart';

enum BrowserStatus { opening, ready, failed }

enum TransferStatus { running, done, failed, cancelled }

/// One download or upload, for the list of transfers.
class Transfer {
  Transfer({required this.id, required this.name, required this.isUpload});

  final int id;
  final String name;
  final bool isUpload;
  int bytes = 0;
  int? total;
  var status = TransferStatus.running;

  /// Why it failed or was not saved.
  String? message;
  final cancel = TransferCancel();

  double? get fraction {
    final t = total;
    if (t == null || t <= 0) return null;
    return (bytes / t).clamp(0.0, 1.0);
  }
}

/// What the file browser shows and does for one host.
///
/// It opens the host's SFTP (sharing an open terminal's connection when it
/// can), lists folders, and runs the file operations and transfers. The
/// screen only draws it and asks the user.
class SftpBrowserController extends ChangeNotifier {
  SftpBrowserController({
    required this.opener,
    required this.server,
    required this.saveDownload,
    this.reuse,
  });

  final SftpOpener opener;
  final ServerConfig server;
  final SSHConnectionSession? reuse;

  /// Hands a finished download to the user. Returns whether it was saved.
  final Future<bool> Function(LocalTempFile file, String name) saveDownload;

  BrowserStatus status = BrowserStatus.opening;
  String? error;
  String path = '/';
  List<RemoteEntry> _entries = const [];
  var _loading = false;
  SortField sortField = SortField.name;
  var descending = false;
  final transfers = <Transfer>[];

  /// A short message for the last operation that failed, shown once.
  String? notice;

  SftpHandle? _handle;
  var _disposed = false;
  var _navigation = 0;
  var _nextTransfer = 1;

  RemoteFileSystem get _files => _handle!.files;

  /// Whether a folder is being read.
  bool get loading => _loading;

  List<RemoteEntry> get entries =>
      sortEntries(_entries, sortField, descending: descending);

  bool get canGoUp => path != '/';

  Future<void> start() async {
    status = BrowserStatus.opening;
    error = null;
    _notify();
    try {
      final handle = await opener(server, reuse: reuse);
      if (_disposed) {
        await handle.release();
        return;
      }
      _handle = handle;
      path = await handle.files.home();
      _entries = await handle.files.list(path);
      status = BrowserStatus.ready;
    } on RemoteFileException catch (e) {
      status = BrowserStatus.failed;
      error = e.message;
    } catch (e) {
      status = BrowserStatus.failed;
      error = "Couldn't open the files. $e";
    }
    _notify();
  }

  /// Opens [directory]. If it cannot be read, the current folder stays.
  Future<void> open(String directory) async {
    final navigation = ++_navigation;
    _loading = true;
    _notify();
    try {
      final entries = await _files.list(directory);
      if (navigation != _navigation || _disposed) return;
      path = directory;
      _entries = entries;
    } on RemoteFileException catch (e) {
      if (navigation == _navigation) notice = e.message;
    } finally {
      if (navigation == _navigation) _loading = false;
      _notify();
    }
  }

  Future<void> up() => open(parentRemote(path));

  Future<void> refresh() => open(path);

  void setSort(SortField field) {
    if (field == sortField) {
      descending = !descending;
    } else {
      sortField = field;
      descending = false;
    }
    _notify();
  }

  /// Runs [action], then reloads the folder. A failure becomes a notice.
  Future<bool> _change(Future<void> Function() action) async {
    try {
      await action();
      await refresh();
      return true;
    } on RemoteFileException catch (e) {
      notice = e.message;
      _notify();
      return false;
    } catch (e) {
      notice = 'That did not work. $e';
      _notify();
      return false;
    }
  }

  Future<bool> createFolder(String name) {
    return _change(() => _files.createFolder(joinRemote(path, name)));
  }

  Future<bool> rename(RemoteEntry entry, String newName) {
    return _change(
      () => _files.rename(
        joinRemote(path, entry.name),
        joinRemote(path, newName),
      ),
    );
  }

  Future<bool> delete(RemoteEntry entry) {
    return _change(
      () => _files.delete(
        joinRemote(path, entry.name),
        isDirectory: entry.isDirectory,
      ),
    );
  }

  /// Entries inside a folder, for the delete warning.
  Future<int> countInside(RemoteEntry entry) async {
    try {
      return await _files.countEntries(joinRemote(path, entry.name));
    } catch (_) {
      return 0;
    }
  }

  /// Downloads [entry] and hands it to the user to save.
  Transfer download(RemoteEntry entry) {
    final transfer = Transfer(
      id: _nextTransfer++,
      name: entry.name,
      isUpload: false,
    );
    transfers.insert(0, transfer);
    _notify();
    unawaited(_runDownload(transfer, joinRemote(path, entry.name)));
    return transfer;
  }

  Future<void> _runDownload(Transfer transfer, String remote) async {
    LocalTempFile? temp;
    try {
      temp = await LocalTempFile.create(transfer.name);
      await for (final chunk in _files.download(
        remote,
        cancel: transfer.cancel,
        onProgress: (bytes, total) {
          transfer
            ..bytes = bytes
            ..total = total;
          _notify();
        },
      )) {
        await temp.add(chunk);
      }
      await temp.close();
      if (transfer.cancel.isCancelled) {
        _finish(transfer, TransferStatus.cancelled);
        return;
      }
      final saved = await saveDownload(temp, transfer.name);
      _finish(
        transfer,
        saved ? TransferStatus.done : TransferStatus.cancelled,
        message: saved ? null : 'Not saved',
      );
    } on TransferCancelled {
      _finish(transfer, TransferStatus.cancelled);
    } on RemoteFileException catch (e) {
      _finish(transfer, TransferStatus.failed, message: e.message);
    } catch (e) {
      _finish(transfer, TransferStatus.failed, message: 'Download failed. $e');
    } finally {
      await temp?.delete();
    }
  }

  /// Uploads [files] into the current folder, one after the other.
  Future<void> upload(List<UploadFile> files) async {
    final folder = path;
    for (final file in files) {
      final transfer = Transfer(
        id: _nextTransfer++,
        name: file.name,
        isUpload: true,
      )..total = file.length;
      transfers.insert(0, transfer);
      _notify();
      try {
        await _files.upload(
          joinRemote(folder, file.name),
          file.open(),
          total: file.length,
          cancel: transfer.cancel,
          onProgress: (bytes, total) {
            transfer
              ..bytes = bytes
              ..total = total ?? transfer.total;
            _notify();
          },
        );
        _finish(transfer, TransferStatus.done);
      } on TransferCancelled {
        _finish(transfer, TransferStatus.cancelled);
      } on RemoteFileException catch (e) {
        _finish(transfer, TransferStatus.failed, message: e.message);
      } catch (e) {
        _finish(transfer, TransferStatus.failed, message: 'Upload failed. $e');
      }
    }
    if (!_disposed && path == folder) await refresh();
  }

  void _finish(Transfer transfer, TransferStatus status, {String? message}) {
    // Cancelling shows at once; what comes later does not undo it.
    if (transfer.status == TransferStatus.cancelled) return;
    transfer
      ..status = status
      ..message = message;
    _notify();
  }

  void cancelTransfer(Transfer transfer) {
    if (transfer.status != TransferStatus.running) return;
    transfer.cancel.cancel();
    transfer.status = TransferStatus.cancelled;
    _notify();
  }

  void dismissTransfer(Transfer transfer) {
    if (transfer.status == TransferStatus.running) return;
    transfers.remove(transfer);
    _notify();
  }

  /// Takes the notice, so it is shown once.
  String? takeNotice() {
    final message = notice;
    notice = null;
    return message;
  }

  bool get hasRunningTransfer =>
      transfers.any((t) => t.status == TransferStatus.running);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final transfer in transfers) {
      transfer.cancel.cancel();
    }
    final handle = _handle;
    _handle = null;
    if (handle != null) unawaited(handle.release());
    super.dispose();
  }
}
