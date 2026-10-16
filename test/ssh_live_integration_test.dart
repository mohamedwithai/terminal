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
/// Skipped unless the target and credentials are set. There are no default
/// host, username, or password values.
///
/// HOW TO RUN:
///   flutter test --tags live --run-skipped test/ssh_live_integration_test.dart
///
/// ENVIRONMENT VARIABLES:
/// - SSH_TEST_HOST              Target host (required)
/// - SSH_TEST_PORT              Target port (optional, default 22)
/// - SSH_TEST_USER              SSH username (required)
/// - SSH_TEST_PASSWORD          Password (required when SSH_TEST_KEY_PATH is unset)
/// - SSH_TEST_KEY_PATH          Private key file (optional; used instead of the password)
/// - SSH_TEST_KEY_PASSPHRASE    Passphrase for that key (optional)
///
/// Example:
///   SSH_TEST_HOST=203.0.113.10 SSH_TEST_USER=ada SSH_TEST_KEY_PATH=~/.ssh/id_ed25519 \
///     flutter test --tags live --run-skipped test/ssh_live_integration_test.dart
void main() {
  final parsed = _parseLiveEnv(Platform.environment);

  test('connects to live sshd, runs "echo ok", verifies output', () async {
    final env = _requireLive(parsed);
    if (env == null) {
      return;
    }

    final server = _server(env);
    final knownHosts = <String, KnownHost>{};
    final session = SSHConnectionSession(
      sessionId: 'live-session-1',
      server: server,
      hostKeyVerifier: _verifier(knownHosts),
      connectTimeout: const Duration(seconds: 5),
    );
    final sub = session.stateStream.listen((state) {
      if (state.challenge != null) {
        state.challenge!.accept();
      }
    });

    try {
      await session.connect(_credentials(env));
      expect(session.isConnected, isTrue);
      final output = await session.execute('echo ok');
      expect(output.trim(), contains('ok'));
    } finally {
      await sub.cancel();
      await session.disconnect();
    }
  });

  test('wrong credentials path throws SSHAuthFailedException', () async {
    final env = _requireLive(parsed);
    if (env == null) {
      return;
    }

    final knownHosts = <String, KnownHost>{};
    final session = SSHConnectionSession(
      sessionId: 'live-session-wrong-auth',
      server: _server(env),
      hostKeyVerifier: _verifier(knownHosts),
      connectTimeout: const Duration(seconds: 5),
    );
    final sub = session.stateStream.listen((state) {
      if (state.challenge != null) {
        state.challenge!.accept();
      }
    });

    try {
      await expectLater(
        session.connect(_wrongCredentials(env)),
        throwsA(isA<SSHAuthFailedException>()),
      );
    } finally {
      await sub.cancel();
      await session.disconnect();
    }
  });

  test('changed host key path throws SSHHostKeyChangedException', () async {
    final env = _requireLive(parsed);
    if (env == null) {
      return;
    }

    final knownHosts = <String, KnownHost>{
      '${env.host}:${env.port}': KnownHost(
        host: env.host,
        port: env.port,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:FAKE_CHANGED_FINGERPRINT_DOES_NOT_MATCH',
        addedAt: DateTime.utc(2026, 1, 1),
      ),
    };
    final session = SSHConnectionSession(
      sessionId: 'live-session-changed-key',
      server: _server(env),
      hostKeyVerifier: _verifier(knownHosts),
      connectTimeout: const Duration(seconds: 5),
    );

    try {
      await expectLater(
        session.connect(_credentials(env)),
        throwsA(isA<SSHHostKeyChangedException>()),
      );
    } finally {
      await session.disconnect();
    }
  });
}

const _skipMessage =
    'Set SSH_TEST_HOST, SSH_TEST_USER, and SSH_TEST_PASSWORD or SSH_TEST_KEY_PATH.';

class _LiveEnv {
  const _LiveEnv({
    required this.host,
    required this.port,
    required this.user,
    required this.authType,
    this.password,
    this.keyPath,
    this.keyPassphrase,
  });

  final String host;
  final int port;
  final String user;
  final AuthType authType;
  final String? password;
  final String? keyPath;
  final String? keyPassphrase;
}

class _LiveParse {
  const _LiveParse({this.env, this.error});

  final _LiveEnv? env;
  final String? error;
}

_LiveParse _parseLiveEnv(Map<String, String> env) {
  final host = env['SSH_TEST_HOST']?.trim() ?? '';
  final user = env['SSH_TEST_USER']?.trim() ?? '';
  final password = env['SSH_TEST_PASSWORD'] ?? '';
  final keyPath = env['SSH_TEST_KEY_PATH']?.trim() ?? '';
  final passphrase = env['SSH_TEST_KEY_PASSPHRASE'];
  final hasPassword = password.isNotEmpty;
  final hasKey = keyPath.isNotEmpty;

  if (host.isEmpty || user.isEmpty || (!hasPassword && !hasKey)) {
    return const _LiveParse();
  }

  final portText = env['SSH_TEST_PORT']?.trim() ?? '';
  var port = 22;
  if (portText.isNotEmpty) {
    final parsed = int.tryParse(portText);
    if (parsed == null || parsed < 1 || parsed > 65535) {
      return const _LiveParse(
        error: 'SSH_TEST_PORT must be an integer from 1 to 65535.',
      );
    }
    port = parsed;
  }

  if (hasKey) {
    return _LiveParse(
      env: _LiveEnv(
        host: host,
        port: port,
        user: user,
        authType: AuthType.privateKey,
        keyPath: keyPath,
        keyPassphrase: (passphrase != null && passphrase.isNotEmpty)
            ? passphrase
            : null,
      ),
    );
  }

  return _LiveParse(
    env: _LiveEnv(
      host: host,
      port: port,
      user: user,
      authType: AuthType.password,
      password: password,
    ),
  );
}

_LiveEnv? _requireLive(_LiveParse parsed) {
  if (parsed.error != null) {
    fail(parsed.error!);
  }
  if (parsed.env == null) {
    markTestSkipped(_skipMessage);
    return null;
  }
  return parsed.env;
}

ServerConfig _server(_LiveEnv env) {
  return ServerConfig.create(
    id: 'live-test-server',
    label: 'Live SSH Test',
    host: env.host,
    port: env.port,
    username: env.user,
    authType: env.authType,
  );
}

HostKeyVerifier _verifier(Map<String, KnownHost> knownHosts) {
  return HostKeyVerifier(
    findKnownHost: (host, port) => knownHosts['$host:$port'],
    saveKnownHost: (knownHost) =>
        knownHosts['${knownHost.host}:${knownHost.port}'] = knownHost,
  );
}

ServerCredentials _credentials(_LiveEnv env) {
  if (env.authType == AuthType.privateKey) {
    return ServerCredentials(
      privateKey: File(env.keyPath!).readAsStringSync(),
      passphrase: env.keyPassphrase,
    );
  }
  return ServerCredentials(password: env.password);
}

ServerCredentials _wrongCredentials(_LiveEnv env) {
  if (env.authType == AuthType.privateKey) {
    return const ServerCredentials(
      privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----\ninvalid\n-----END OPENSSH PRIVATE KEY-----',
    );
  }
  return const ServerCredentials(password: 'definitely-wrong-password-xyz123');
}
