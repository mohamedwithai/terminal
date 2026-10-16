import 'dart:async';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/services/ssh/host_key_verifier.dart';
import 'package:ssh_app/services/ssh/ssh_connection_session.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';
import 'package:ssh_app/services/ssh/ssh_errors.dart';

import 'support/fake_ssh.dart';

void main() {
  group('SSHConnectionSession unit tests', () {
    final server = ServerConfig.create(
      id: 'srv-1',
      label: 'Test Server',
      host: '10.0.0.1',
      port: 22,
      username: 'testuser',
      authType: AuthType.password,
    );

    final credentials = const ServerCredentials(password: 'secret');

    final dummyVerifier = HostKeyVerifier(
      findKnownHost: (_, _) => null,
      saveKnownHost: (_) {},
    );

    test('initial state is disconnected', () {
      final session = SSHConnectionSession(
        sessionId: 'session-1',
        server: server,
        hostKeyVerifier: dummyVerifier,
      );
      expect(session.state.status, SSHConnectionStatus.disconnected);
      expect(session.isConnected, isFalse);
    });

    test('socket connection timeout transitions to error with SSHTimeoutException', () async {
      final fakeFactory = FakeSSHSocketFactory(
        onConnect: (h, p, to) async {
          await Future.delayed(const Duration(milliseconds: 50));
          throw TimeoutException('Timed out');
        },
      );

      final session = SSHConnectionSession(
        sessionId: 'session-1',
        server: server,
        hostKeyVerifier: dummyVerifier,
        socketFactory: fakeFactory,
        connectTimeout: const Duration(milliseconds: 20),
      );

      final states = <SSHConnectionStatus>[];
      final sub = session.stateStream.listen((s) => states.add(s.status));

      await expectLater(
        session.connect(credentials),
        throwsA(isA<SSHTimeoutException>()),
      );

      expect(session.state.status, SSHConnectionStatus.error);
      expect(session.state.error, isA<SSHTimeoutException>());
      await sub.cancel();
    });

    test('connection refused transitions to error with SSHConnectionRefusedException', () async {
      final fakeFactory = FakeSSHSocketFactory(
        onConnect: (h, p, to) => throw const SocketException(
          'Connection refused',
          osError: OSError('Connection refused', 111),
        ),
      );

      final session = SSHConnectionSession(
        sessionId: 'session-1',
        server: server,
        hostKeyVerifier: dummyVerifier,
        socketFactory: fakeFactory,
      );

      final states = <SSHConnectionStatus>[];
      final sub = session.stateStream.listen((s) => states.add(s.status));

      await expectLater(
        session.connect(credentials),
        throwsA(isA<SSHConnectionRefusedException>()),
      );

      expect(session.state.status, SSHConnectionStatus.error);
      expect(session.state.error, isA<SSHConnectionRefusedException>());
      await sub.cancel();
    });

    test('DNS failure transitions to error with SSHDnsException', () async {
      final fakeFactory = FakeSSHSocketFactory(
        onConnect: (h, p, to) => throw const SocketException(
          'Failed host lookup: non-existent-domain.xyz',
        ),
      );

      final session = SSHConnectionSession(
        sessionId: 'session-1',
        server: server.copyWith(host: 'non-existent-domain.xyz'),
        hostKeyVerifier: dummyVerifier,
        socketFactory: fakeFactory,
      );

      await expectLater(
        session.connect(credentials),
        throwsA(isA<SSHDnsException>()),
      );

      expect(session.state.error, isA<SSHDnsException>());
    });

    test('missing private key for privateKey auth throws SSHAuthFailedException without retry', () async {
      final keyServer = server.copyWith(authType: AuthType.privateKey);
      final session = SSHConnectionSession(
        sessionId: 'session-1',
        server: keyServer,
        hostKeyVerifier: dummyVerifier,
        socketFactory: FakeSSHSocketFactory(onConnect: (h, p, to) async {
          throw const SocketException('Should not even connect socket');
        }),
      );

      final states = <SSHConnectionStatus>[];
      final sub = session.stateStream.listen((s) => states.add(s.status));

      await expectLater(
        session.connect(const ServerCredentials(password: 'not-a-key')),
        throwsA(isA<SSHAuthFailedException>()),
      );

      expect(session.state.status, SSHConnectionStatus.error);
      expect(session.state.error, isA<SSHAuthFailedException>());
      await sub.cancel();
    });

    test('disconnect() voluntarily transitions to disconnected and cancels any retry', () async {
      final session = SSHConnectionSession(
        sessionId: 'session-1',
        server: server,
        hostKeyVerifier: dummyVerifier,
      );

      await session.disconnect();
      expect(session.state.status, SSHConnectionStatus.disconnected);
    });
  });

  group('SSHConnectionSession stages, timeouts and log', () {
    final server = ServerConfig.create(
      id: 'srv-2',
      label: 'Stage Server',
      host: '10.0.0.2',
      port: 2222,
      username: 'ada',
      authType: AuthType.password,
    );
    final verifier = HostKeyVerifier(
      findKnownHost: (_, _) => null,
      saveKnownHost: (_) {},
    );

    test('a server that never answers the handshake times out while exchanging keys', () async {
      final socket = SilentSSHSocket();
      final session = SSHConnectionSession(
        sessionId: 'stages',
        server: server,
        hostKeyVerifier: verifier,
        socketFactory: FakeSSHSocketFactory(onConnect: (h, p, to) async => socket),
        handshakeTimeout: const Duration(milliseconds: 100),
      );
      final states = <SSHConnectionState>[];
      final sub = session.stateStream.listen(states.add);

      await expectLater(
        session.connect(const ServerCredentials(password: 'hunter2-secret')),
        throwsA(isA<SSHTimeoutException>().having(
          (e) => e.message,
          'message',
          contains('while exchanging keys'),
        )),
      );
      await pumpEventQueue();

      expect(states.map((s) => s.stage).toList(), [
        SSHConnectionStage.loadingCredentials,
        SSHConnectionStage.openingConnection,
        SSHConnectionStage.exchangingKeys,
        SSHConnectionStage.exchangingKeys,
      ]);
      expect(states.last.status, SSHConnectionStatus.error);
      expect(socket.wasClosed, isTrue);

      final log = session.log.format();
      expect(log, contains('Opening TCP connection to 10.0.0.2:2222'));
      expect(log, contains('TCP connection open'));
      expect(log, contains('Exchanging keys'));
      expect(log, contains('TimeoutException after'));
      expect(log, isNot(contains('hunter2-secret')));
      expect(
        session.log.entries.last.toString(),
        matches(RegExp(r'^\d\d:\d\d:\d\d\.\d{3}  ERROR ')),
      );
      await sub.cancel();
      session.dispose();
    });

    test('a TCP connect that never completes times out after connectTimeout', () async {
      final session = SSHConnectionSession(
        sessionId: 'tcp',
        server: server,
        hostKeyVerifier: verifier,
        socketFactory: FakeSSHSocketFactory(
          onConnect: (h, p, to) => Completer<SSHSocket>().future,
        ),
        connectTimeout: const Duration(milliseconds: 50),
      );

      await expectLater(
        session.connect(const ServerCredentials(password: 'p')),
        throwsA(isA<SSHTimeoutException>().having(
          (e) => e.message,
          'message',
          startsWith('Could not open a TCP connection to 10.0.0.2:2222'),
        )),
      );
      expect(session.state.status, SSHConnectionStatus.error);
      expect(session.state.stage, SSHConnectionStage.openingConnection);
      session.dispose();
    });

    test('an OS-level connect timeout is reported as a timeout', () async {
      final session = SSHConnectionSession(
        sessionId: 'os-timeout',
        server: server,
        hostKeyVerifier: verifier,
        socketFactory: FakeSSHSocketFactory(
          onConnect: (h, p, to) => throw const SocketException(
            'Connection timed out',
            osError: OSError('Connection timed out', 110),
          ),
        ),
      );

      await expectLater(
        session.connect(const ServerCredentials(password: 'p')),
        throwsA(isA<SSHTimeoutException>()),
      );
      expect(session.log.format(), contains('Connection timed out'));
      session.dispose();
    });

    test('missing, failing and hanging credentials end in an error state', () async {
      Future<SSHConnectionState> failWith(CredentialsLoader loader) async {
        final session = SSHConnectionSession(
          sessionId: 'creds',
          server: server,
          hostKeyVerifier: verifier,
          socketFactory: FakeSSHSocketFactory(onConnect: (h, p, to) {
            fail('Must not open a socket without credentials.');
          }),
          credentialsTimeout: const Duration(milliseconds: 50),
        );
        await expectLater(
          session.connectWith(loader),
          throwsA(isA<SSHCredentialsException>()),
        );
        final state = session.state;
        session.dispose();
        return state;
      }

      final missing = await failWith(() => null);
      expect(missing.errorMessage, contains('No saved credentials'));
      expect(missing.stage, SSHConnectionStage.loadingCredentials);

      final failing = await failWith(() => throw StateError('keystore broke'));
      expect(failing.errorMessage, contains('keystore broke'));

      final hanging = await failWith(() => Completer<ServerCredentials?>().future);
      expect(hanging.errorMessage, contains('took longer than'));
    });

    test('disconnect() during the handshake abandons the attempt quietly', () async {
      final socket = SilentSSHSocket();
      final session = SSHConnectionSession(
        sessionId: 'cancel',
        server: server,
        hostKeyVerifier: verifier,
        socketFactory: FakeSSHSocketFactory(onConnect: (h, p, to) async => socket),
      );
      final attempt = session.connect(const ServerCredentials(password: 'p'));
      await pumpEventQueue();
      expect(session.state.stage, SSHConnectionStage.exchangingKeys);

      await session.disconnect();
      await expectLater(attempt, throwsA(isA<SSHConnectionException>()));
      await pumpEventQueue();

      expect(session.state.status, SSHConnectionStatus.disconnected);
      expect(socket.wasClosed, isTrue);
      session.dispose();
    });
  });
}
