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
import 'package:ssh_app/services/ssh/ssh_socket_factory.dart';

class FakeSSHSocketFactory implements SSHSocketFactory {
  FakeSSHSocketFactory({
    this.onConnect,
  });

  Future<SSHSocket> Function(String host, int port, Duration? timeout)? onConnect;

  @override
  Future<SSHSocket> connect(String host, int port, {Duration? timeout}) {
    if (onConnect != null) {
      return onConnect!(host, port, timeout);
    }
    throw const SocketException('Connection refused', osError: OSError('Connection refused', 111));
  }
}

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
}
