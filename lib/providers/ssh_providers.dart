import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/services/ssh/host_key_verifier.dart';
import 'package:ssh_app/services/ssh/ssh_connection_service.dart';
import 'package:ssh_app/services/ssh/ssh_connection_session.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';

/// Riverpod provider for the global [SSHConnectionService].
final sshConnectionServiceProvider = Provider<SSHConnectionService>((ref) {
  final metadataStore = ref.watch(metadataStoreProvider);

  final verifier = HostKeyVerifier(
    findKnownHost: (host, port) => metadataStore.getKnownHost(host, port),
    saveKnownHost: (knownHost) => metadataStore.putKnownHost(knownHost),
  );

  final service = SSHConnectionService(hostKeyVerifier: verifier);
  ref.onDispose(service.dispose);
  return service;
});

/// Stream of connection state snapshots for a specific session.
final sshSessionStateProvider =
    StreamProvider.autoDispose.family<SSHConnectionState, ({String sessionId, ServerConfig server})>(
  (ref, args) {
    if (kIsWeb) {
      return Stream.value(
        const SSHConnectionState.error(
          'SSH connections require raw sockets and are not supported on Flutter Web.',
        ),
      );
    }

    final service = ref.watch(sshConnectionServiceProvider);
    final session = service.getOrCreateSession(args.sessionId, args.server);

    ref.onDispose(() {
      service.closeSession(args.sessionId);
    });

    return session.stateStream;
  },
);

/// Controller managing connection actions (connect, disconnect, execute) for a session.
final sshSessionControllerProvider = Provider.autoDispose
    .family<SSHSessionController, ({String sessionId, ServerConfig server})>(
  (ref, args) {
    return SSHSessionController(ref: ref, sessionId: args.sessionId, server: args.server);
  },
);

class SSHSessionController {
  SSHSessionController({
    required this.ref,
    required this.sessionId,
    required this.server,
  });

  final Ref ref;
  final String sessionId;
  final ServerConfig server;

  SSHConnectionSession? get _session {
    if (kIsWeb) return null;
    return ref.read(sshConnectionServiceProvider).getSession(sessionId);
  }

  /// Loads secrets from [VaultService] and connects.
  Future<void> connect() async {
    if (kIsWeb) {
      return;
    }
    final vault = ref.read(vaultServiceProvider);
    final credentials = await vault.readCredentials(server.id);
    if (credentials == null) {
      throw StateError('Credentials for server "${server.label}" not found in vault.');
    }

    final session = ref
        .read(sshConnectionServiceProvider)
        .getOrCreateSession(sessionId, server);

    await session.connect(credentials);
  }

  Future<void> disconnect() async {
    await _session?.disconnect();
  }

  Future<String> execute(String command) async {
    final session = _session;
    if (session == null) {
      throw StateError('Session not found.');
    }
    return session.execute(command);
  }
}
