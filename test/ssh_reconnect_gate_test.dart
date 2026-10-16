import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/services/ssh/reconnect_gate.dart';
import 'package:ssh_app/services/ssh/ssh_connection_service.dart';
import 'package:ssh_app/services/ssh/ssh_connection_session.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';

import 'support/fake_ssh.dart';
import 'support/fake_terminal_session.dart';

void main() {
  final server = ServerConfig.create(
    id: 'srv-1',
    label: 'Test Server',
    host: '10.0.0.1',
    username: 'testuser',
    authType: AuthType.password,
  );
  const credentials = ServerCredentials(password: 'secret');
  const delays = [
    Duration(milliseconds: 5),
    Duration(milliseconds: 5),
    Duration(milliseconds: 5),
  ];

  /// A session whose every connection attempt is refused.
  ({SSHConnectionSession session, FakeSSHSocketFactory sockets}) setUpSession(
    ReconnectGate gate,
  ) {
    final sockets = FakeSSHSocketFactory();
    final session = SSHConnectionSession(
      sessionId: 'session-1',
      server: server,
      hostKeyVerifier: noKnownHosts(),
      socketFactory: sockets,
      reconnectDelays: delays,
      reconnectGate: gate,
    );
    addTearDown(session.dispose);
    return (session: session, sockets: sockets);
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 60));

  test('in the background a lost session waits without trying', () async {
    final gate = ReconnectGate(foreground: false);
    final (:session, :sockets) = setUpSession(gate);

    session.debugSimulateConnectionLost(credentials);
    await settle();

    expect(sockets.calls, isEmpty);
    expect(session.state.status, SSHConnectionStatus.reconnecting);
    expect(session.state.waitingFor, 'the app to return to the foreground');
    expect(session.isActive, isTrue);
    expect(
      session.log.entries.map((entry) => entry.message),
      contains(
        'Waiting for the app to return to the foreground before '
        'reconnecting',
      ),
    );

    // Back in the foreground: the attempts start, all three of them.
    gate.foreground = true;
    await settle();

    expect(sockets.calls, hasLength(3));
    expect(session.state.status, SSHConnectionStatus.error);
    expect(session.state.errorMessage, contains('after 3 attempts'));
  });

  test('offline it waits for a network connection', () async {
    final gate = ReconnectGate(online: false);
    final (:session, :sockets) = setUpSession(gate);

    session.debugSimulateConnectionLost(credentials);
    await settle();

    expect(sockets.calls, isEmpty);
    expect(session.state.waitingFor, 'a network connection');

    gate.online = true;
    await settle();
    expect(sockets.calls, hasLength(3));
  });

  test(
    'an attempt that fails after going to the background is not counted',
    () async {
      final gate = ReconnectGate();
      final (:session, :sockets) = setUpSession(gate);
      sockets.onConnect = (host, port, timeout) async {
        if (sockets.calls.length == 2) {
          // The user switches away while the second attempt is connecting.
          gate.foreground = false;
        }
        throw const SocketException(
          'Software caused connection abort',
          osError: OSError('Software caused connection abort', 103),
        );
      };

      session.debugSimulateConnectionLost(credentials);
      await settle();

      expect(sockets.calls, hasLength(2));
      expect(session.state.status, SSHConnectionStatus.reconnecting);
      expect(session.state.waitingFor, isNotNull);

      // Returning starts over with every attempt.
      gate.foreground = true;
      await settle();
      expect(sockets.calls, hasLength(5));
      expect(session.state.status, SSHConnectionStatus.error);
    },
  );

  test(
    'a scheduled attempt is held back when the app goes to the background',
    () async {
      final gate = ReconnectGate();
      final sockets = FakeSSHSocketFactory();
      final session = SSHConnectionSession(
        sessionId: 'session-1',
        server: server,
        hostKeyVerifier: noKnownHosts(),
        socketFactory: sockets,
        reconnectDelays: const [Duration(milliseconds: 40)],
        reconnectGate: gate,
      );
      addTearDown(session.dispose);

      session.debugSimulateConnectionLost(credentials);
      expect(session.state.reconnectAttempt, 1);
      gate.foreground = false;
      await settle();

      expect(sockets.calls, isEmpty);
      expect(session.state.waitingFor, isNotNull);
    },
  );

  test('disconnect() while waiting stops the reconnect', () async {
    final gate = ReconnectGate(foreground: false);
    final (:session, :sockets) = setUpSession(gate);

    session.debugSimulateConnectionLost(credentials);
    await session.disconnect();
    gate.foreground = true;
    await settle();

    expect(sockets.calls, isEmpty);
    expect(session.state.status, SSHConnectionStatus.disconnected);
  });

  test('an auth failure is never retried', () async {
    final gate = ReconnectGate();
    final keySession = SSHConnectionSession(
      sessionId: 'session-1',
      server: server.copyWith(authType: AuthType.privateKey),
      hostKeyVerifier: noKnownHosts(),
      socketFactory: FakeSSHSocketFactory(),
      reconnectDelays: delays,
      reconnectGate: gate,
    );
    addTearDown(keySession.dispose);

    keySession.debugSimulateConnectionLost(credentials);
    await settle();

    expect(keySession.state.status, SSHConnectionStatus.error);
    expect(keySession.state.errorMessage, contains('Missing private key'));
  });

  test('the service lists active sessions and disconnects them all', () async {
    final gate = ReconnectGate(online: false);
    final service = SSHConnectionService(
      hostKeyVerifier: noKnownHosts(),
      socketFactory: FakeSSHSocketFactory(),
      reconnectGate: gate,
    );
    addTearDown(service.dispose);
    final changes = <void>[];
    final sub = service.changes.listen(changes.add);
    addTearDown(sub.cancel);

    final session = service.getOrCreateSession('session-1', server);
    expect(service.activeSessions, isEmpty);

    session.debugSimulateConnectionLost(credentials);
    await settle();
    expect(service.activeSessions, [session]);
    expect(changes, isNotEmpty);

    await service.disconnectAll();
    expect(service.activeSessions, isEmpty);
    expect(session.state.status, SSHConnectionStatus.disconnected);
  });
}
