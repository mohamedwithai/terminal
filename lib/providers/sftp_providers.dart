import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:ssh_app/providers/app_lock_providers.dart';
import 'package:ssh_app/providers/ssh_providers.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/services/sftp/local_temp_file.dart';
import 'package:ssh_app/services/sftp/sftp_opener.dart';

/// How SFTP is opened. Tests replace this with a fake file system.
final sftpOpenerProvider = Provider<SftpOpener>((ref) {
  return SshSftpOpener(
    connections: ref.watch(sshConnectionServiceProvider),
    vault: ref.watch(vaultServiceProvider),
  ).open;
});

/// A file chosen to upload.
class UploadFile {
  const UploadFile({
    required this.name,
    required this.length,
    required this.open,
  });

  final String name;
  final int? length;

  /// A fresh stream of the file's bytes.
  final Stream<Uint8List> Function() open;
}

/// Opens the system file picker and returns the chosen files (none if the
/// user backs out). Tests replace it.
final uploadPickerProvider = Provider<Future<List<UploadFile>> Function()>((
  ref,
) {
  return () => ref.read(appLockProvider.notifier).runExternal(() async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Choose files to upload',
    );
    return [
      for (final file in picked)
        UploadFile(
          name: file.name,
          length: await file.length(),
          open: file.readAsByteStream,
        ),
    ];
  });
});

/// Hands a downloaded file to the user: the system "save as" dialog for
/// ordinary sizes, the share sheet for big ones. Returns whether it was
/// saved or shared. Tests replace it.
final fileSaverProvider =
    Provider<Future<bool> Function(LocalTempFile file, String name)>((ref) {
      return (file, name) =>
          ref.read(appLockProvider.notifier).runExternal(() async {
            const inMemoryLimit = 48 * 1024 * 1024;
            if (await file.length() <= inMemoryLimit) {
              final saved = await FilePicker.saveFile(
                fileName: name,
                bytes: await file.readAll(),
              );
              return saved != null;
            }
            final result = await SharePlus.instance.share(
              ShareParams(files: [XFile(file.path)], subject: name),
            );
            return result.status != ShareResultStatus.dismissed;
          });
    });
