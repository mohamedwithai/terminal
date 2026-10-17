import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/services/ssh/connection_log.dart';
import 'package:ssh_app/services/ssh/host_key_verifier.dart';
import 'package:ssh_app/services/ssh/reconnect_gate.dart';
import 'package:ssh_app/services/ssh/ssh_connection_service.dart';
import 'package:ssh_app/services/ssh/ssh_connection_session.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';
import 'package:ssh_app/services/ssh/ssh_socket_factory.dart';

/// Opens TCP connections. Tests override this with fake sockets.
final sshSocketFactoryProvider = Provider<SSHSocketFactory>((ref) {
  return const DefaultSSHSocketFactory();
});

/// Whether lost sessions may try to reconnect. `sessionKeeperProvider` keeps
/// it up to date with the app's lifecycle and the network; until then it is
/// open.
final reconnectGateProvider = Provider<ReconnectGate>((ref) {
  final gate = ReconnectGate();
  ref.onDispose(gate.dispose);
  return gate;
});

/// Riverpod provider for the global [SSHConnectionService].
final sshConnectionServiceProvider = Provider<SSHConnectionService>((ref) {
  final metadataStore = ref.watch(metadataStoreProvider);

  final verifier = HostKeyVerifier(
    findKnownHost: (host, port) => metadataStore.getKnownHost(host, port),
    saveKnownHost: (knownHost) => metadataStore.putKnownHost(knownHost),
  );

  final service = SSHConnectionService(
    hostKeyVerifier: verifier,
    socketFactory: ref.watch(sshSocketFactoryProvider),
    reconnectGate: ref.watch(reconnectGateProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// What time it is. Tests and golden files pin it.
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Sessions that are connected or getting a lost connection back.
final activeSessionsProvider = StreamProvider<List<SSHConnectionSession>>((
  ref,
) {
  if (kIsWeb) {
    return Stream.value(const []);
  }
  final service = ref.watch(sshConnectionServiceProvider);
  return Stream.multi((controller) {
    controller.add(service.activeSessions);
    final sub = service.changes.listen(
      (_) => controller.add(service.activeSessions),
    );
    controller.onCancel = sub.cancel;
  });
});

/// Stream of connection state snapshots for a specific session.
final sshSessionStateProvider = StreamProvider.autoDispose
    .family<SSHConnectionState, ({String sessionId, ServerConfig server})>((
      ref,
      args,
    ) {
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
    });

/// The session's connection log, emitted in full after every new entry.
final sshSessionLogProvider = StreamProvider.autoDispose
    .family<
      List<ConnectionLogEntry>,
      ({String sessionId, ServerConfig server})
    >((ref, args) {
      if (kIsWeb) {
        return Stream.value(const []);
      }

      final log = ref
          .watch(sshConnectionServiceProvider)
          .getOrCreateSession(args.sessionId, args.server)
          .log;
      // Start with the entries so far, then follow changes, with no gap
      // between the two in which an entry could be missed.
      return Stream.multi((controller) {
        controller.add(log.entries);
        final sub = log.changes.listen(
          controller.add,
          onDone: controller.close,
        );
        controller.onCancel = sub.cancel;
      });
    });

/// Controller managing connection actions (connect, disconnect, execute) for a session.
final sshSessionControllerProvider = Provider.autoDispose
    .family<SSHSessionController, ({String sessionId, ServerConfig server})>((
      ref,
      args,
    ) {
      return SSHSessionController(
        ref: ref,
        sessionId: args.sessionId,
        server: args.server,
      );
    });

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
  ///
  /// Everything is read from [ref] before the first `await`. This provider
  /// is auto-disposed and usually only `read`, so by the time the vault
  /// answers its [ref] has been disposed and would throw.
  Future<void> connect() async {
    if (kIsWeb) {
      return;
    }
    final vault = ref.read(vaultServiceProvider);
    final session = ref
        .read(sshConnectionServiceProvider)
        .getOrCreateSession(sessionId, server);

    await session.connectWith(() => vault.readCredentials(server.id));
  }

  /// Opens the interactive shell, which the terminal screen then takes over.
  Future<void> openShell() async {
    final session = _session;
    if (session == null) {
      throw StateError('Session not found.');
    }
    await session.openShell();
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
