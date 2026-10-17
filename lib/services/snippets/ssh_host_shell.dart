import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/services/snippets/multi_host_run.dart';
import 'package:ssh_app/services/ssh/ssh_connection_service.dart';
import 'package:ssh_app/services/ssh/ssh_connection_session.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';
import 'package:ssh_app/services/ssh/ssh_errors.dart';
import 'package:ssh_app/services/vault_service.dart';

/// Opens snippet shells over SSH, using the saved credentials.
///
/// Nobody is there to answer a question, so a host key that is not already
/// saved is refused: connect to the host once from the Hosts tab and trust
/// it first.
class SshHostShellOpener {
  SshHostShellOpener({required this.connections, required this.vault});

  final SSHConnectionService connections;
  final VaultService vault;
  var _counter = 0;

  Future<HostShell> open(ServerConfig server) async {
    final sessionId =
        'snippet-${DateTime.now().microsecondsSinceEpoch}-${_counter++}';
    final session = connections.getOrCreateSession(sessionId, server);
    final watch = session.stateStream.listen((state) {
      if (state.status == SSHConnectionStatus.awaitingHostKeyConfirmation) {
        state.challenge?.reject();
      }
    });
    try {
      await session.connectWith(() => vault.readCredentials(server.id));
      final shell = await session.openShell();
      return _SshHostShell(connections, sessionId, session, shell);
    } on SSHHostKeyRejectedException {
      connections.closeSession(sessionId);
      throw const HostRunException(
        'Host key not trusted yet. Open this host once from Hosts and trust it.',
      );
    } on SSHConnectionException catch (error) {
      connections.closeSession(sessionId);
      throw HostRunException(error.message);
    } catch (error) {
      connections.closeSession(sessionId);
      throw HostRunException("Couldn't connect. $error");
    } finally {
      unawaited(watch.cancel());
    }
  }
}

class _SshHostShell implements HostShell {
  _SshHostShell(this._connections, this._sessionId, this._session, this._shell);

  final SSHConnectionService _connections;
  final String _sessionId;
  final SSHConnectionSession _session;
  final SSHSession _shell;

  @override
  Stream<String> get output => _shell.stdout.cast<List<int>>().transform(
    const Utf8Decoder(allowMalformed: true),
  );

  @override
  void write(String text) => _session.writeShell(utf8.encode(text));

  @override
  Future<void> close() async {
    await _session.disconnect();
    _connections.closeSession(_sessionId);
  }
}
