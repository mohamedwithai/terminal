@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/known_host.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/services/ssh/host_key_verifier.dart';
import 'package:ssh_app/services/ssh/ssh_connection_session.dart';
import 'package:ssh_app/services/ssh/ssh_errors.dart';

/// LIVE SSH INTEGRATION TEST
///
/// HOW TO RUN:
/// Ensure an SSH server is running on the target machine, then run:
///   dart test --tags live
///
/// CONFIGURATION VIA ENVIRONMENT VARIABLES:
/// - SSH_TEST_HOST     Target host (default: '127.0.0.1')
/// - SSH_TEST_PORT     Target port (default: 22)
/// - SSH_TEST_USER     SSH username (default: 'testuser')
/// - SSH_TEST_PASSWORD SSH password (default: 'testpass')
///
/// Example:
///   $env:SSH_TEST_HOST="127.0.0.1"; $env:SSH_TEST_PORT="22"; $env:SSH_TEST_USER="hasan"; dart test -t live
void main() {
  final host = Platform.environment['SSH_TEST_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(Platform.environment['SSH_TEST_PORT'] ?? '22') ?? 22;
  final user = Platform.environment['SSH_TEST_USER'] ?? 'testuser';
  final password = Platform.environment['SSH_TEST_PASSWORD'] ?? 'testpass';

  final server = ServerConfig.create(
    id: 'live-test-server',
    label: 'Live Localhost Test',
    host: host,
    port: port,
    username: user,
    authType: AuthType.password,
  );

  setUpAll(() async {
    // Quick connectivity pre-check so failure messages are crystal clear
    try {
      final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      socket.destroy();
    } catch (e) {
      stderr.writeln(
        '\n[NOTICE] Could not connect to sshd at $host:$port ($e).\n'
        'To run the live integration test, start an SSH server or configure '
        'SSH_TEST_HOST, SSH_TEST_PORT, SSH_TEST_USER, and SSH_TEST_PASSWORD.\n',
      );
    }
  });

  test('connects to live sshd, runs "echo ok", verifies output', () async {
    final knownHosts = <String, KnownHost>{};
    final verifier = HostKeyVerifier(
      findKnownHost: (h, p) => knownHosts['$h:$p'],
      saveKnownHost: (kh) => knownHosts['${kh.host}:${kh.port}'] = kh,
    );

    final session = SSHConnectionSession(
      sessionId: 'live-session-1',
      server: server,
      hostKeyVerifier: verifier,
      connectTimeout: const Duration(seconds: 5),
    );

    try {
      // Connect and accept host key if challenged
      final connectFuture = session.connect(ServerCredentials(password: password));

      // Listen for challenge to automatically accept
      final sub = session.stateStream.listen((state) {
        if (state.challenge != null) {
          state.challenge!.accept();
        }
      });

      await connectFuture;
      await sub.cancel();

      expect(session.isConnected, isTrue);

      final output = await session.execute('echo ok');
      expect(output.trim(), contains('ok'));
    } finally {
      await session.disconnect();
    }
  });

  test('wrong password path throws SSHAuthFailedException', () async {
    final knownHosts = <String, KnownHost>{};
    final verifier = HostKeyVerifier(
      findKnownHost: (h, p) => knownHosts['$h:$p'],
      saveKnownHost: (kh) => knownHosts['${kh.host}:${kh.port}'] = kh,
    );

    final session = SSHConnectionSession(
      sessionId: 'live-session-wrong-pw',
      server: server,
      hostKeyVerifier: verifier,
      connectTimeout: const Duration(seconds: 5),
    );

    try {
      final connectFuture = session.connect(
        const ServerCredentials(password: 'definitely-wrong-password-xyz123'),
      );

      final sub = session.stateStream.listen((state) {
        if (state.challenge != null) {
          state.challenge!.accept();
        }
      });

      await expectLater(
        connectFuture,
        throwsA(isA<SSHAuthFailedException>()),
      );
      await sub.cancel();
    } finally {
      await session.disconnect();
    }
  });

  test('changed host key path throws SSHHostKeyChangedException', () async {
    final knownHosts = <String, KnownHost>{
      '$host:$port': KnownHost(
        host: host,
        port: port,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:FAKE_CHANGED_FINGERPRINT_DOES_NOT_MATCH',
        addedAt: DateTime.utc(2026, 1, 1),
      ),
    };

    final verifier = HostKeyVerifier(
      findKnownHost: (h, p) => knownHosts['$h:$p'],
      saveKnownHost: (kh) => knownHosts['${kh.host}:${kh.port}'] = kh,
    );

    final session = SSHConnectionSession(
      sessionId: 'live-session-changed-key',
      server: server,
      hostKeyVerifier: verifier,
      connectTimeout: const Duration(seconds: 5),
    );

    try {
      await expectLater(
        session.connect(ServerCredentials(password: password)),
        throwsA(isA<SSHHostKeyChangedException>()),
      );
    } finally {
      await session.disconnect();
    }
  });
}
