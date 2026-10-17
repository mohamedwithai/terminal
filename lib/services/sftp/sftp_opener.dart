import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/services/sftp/remote_file_system.dart';
import 'package:ssh_app/services/sftp/sftp_file_system.dart';
import 'package:ssh_app/services/ssh/ssh_connection_service.dart';
import 'package:ssh_app/services/ssh/ssh_connection_session.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';
import 'package:ssh_app/services/ssh/ssh_errors.dart';
import 'package:ssh_app/services/vault_service.dart';

/// The remote files of a host, and how to let go of them.
class SftpHandle {
  const SftpHandle(this.files, this.release);

  final RemoteFileSystem files;

  /// Closes the SFTP channel and, if this opened its own connection, that
  /// too. A connection that belongs to a terminal is left open.
  final Future<void> Function() release;
}

/// Opens the files of [server]. With [reuse], an open terminal's session, its
/// connection is shared; otherwise a connection is made for the browser.
typedef SftpOpener = Future<SftpHandle> Function(
  ServerConfig server, {
  SSHConnectionSession? reuse,
});

/// [SftpOpener] over real SSH. A host key that is not already saved is
/// refused: connect to the host once from a terminal and trust it first.
class SshSftpOpener {
  SshSftpOpener({required this.connections, required this.vault});

  final SSHConnectionService connections;
  final VaultService vault;
  var _counter = 0;

  Future<SftpHandle> open(
    ServerConfig server, {
    SSHConnectionSession? reuse,
  }) async {
    final shared = reuse?.client;
    if (reuse != null && reuse.isConnected && shared != null) {
      return _handle(await _channel(shared), null);
    }

    final id = 'files-${DateTime.now().microsecondsSinceEpoch}-${_counter++}';
    final session = connections.getOrCreateSession(id, server);
    final watch = session.stateStream.listen((state) {
      if (state.status == SSHConnectionStatus.awaitingHostKeyConfirmation) {
        state.challenge?.reject();
      }
    });
    try {
      await session.connectWith(() => vault.readCredentials(server.id));
      final client = session.client;
      if (client == null) {
        throw const RemoteFileException("Couldn't connect.");
      }
      return _handle(await _channel(client), () async {
        await session.disconnect();
        connections.closeSession(id);
      });
    } on SSHHostKeyRejectedException {
      connections.closeSession(id);
      throw const RemoteFileException(
        'Host key not trusted yet. Open this host in a terminal once and '
        'trust it.',
      );
    } on SSHConnectionException catch (error) {
      connections.closeSession(id);
      throw RemoteFileException(error.message);
    } on RemoteFileException {
      connections.closeSession(id);
      rethrow;
    } catch (error) {
      connections.closeSession(id);
      throw RemoteFileException("Couldn't connect. $error");
    } finally {
      unawaited(watch.cancel());
    }
  }

  Future<SftpFileSystem> _channel(SSHClient client) async {
    try {
      return SftpFileSystem(await client.sftp());
    } catch (error) {
      throw RemoteFileException(
        'This server does not offer SFTP, or refused it. $error',
      );
    }
  }

  SftpHandle _handle(SftpFileSystem files, Future<void> Function()? closeOwn) {
    return SftpHandle(files, () async {
      await files.close();
      await closeOwn?.call();
    });
  }
}
