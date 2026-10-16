import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/models/known_host.dart';
import 'package:ssh_app/services/ssh/host_key_verifier.dart';
import 'package:ssh_app/services/ssh/ssh_errors.dart';

void main() {
  group('HostKeyVerifier (TOFU)', () {
    final fingerprintBytes = Uint8List.fromList([
      1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
      17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
    ]);
    final expectedFp = HostKeyVerifier.formatFingerprint(fingerprintBytes);

    test('formatFingerprint produces standard OpenSSH SHA256 format', () {
      expect(expectedFp, startsWith('SHA256:'));
      expect(expectedFp, isNot(contains('=')));
    });

    test('known host with matching fingerprint returns true without challenge', () async {
      final store = <String, KnownHost>{
        'server.com:22': KnownHost(
          host: 'server.com',
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprint: expectedFp,
          addedAt: DateTime.utc(2026, 1, 1),
        ),
      };

      var challengeCalled = false;
      final verifier = HostKeyVerifier(
        findKnownHost: (h, p) => store['$h:$p'],
        saveKnownHost: (kh) => store['${kh.host}:${kh.port}'] = kh,
      );

      final result = await verifier.verify(
        host: 'server.com',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprintBytes: fingerprintBytes,
        onChallenge: (challenge) async {
          challengeCalled = true;
          return true;
        },
      );

      expect(result, isTrue);
      expect(challengeCalled, isFalse);
    });

    test('known host with CHANGED fingerprint throws SSHHostKeyChangedException (never auto-accept)', () async {
      final store = <String, KnownHost>{
        'server.com:22': KnownHost(
          host: 'server.com',
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprint: 'SHA256:original-fingerprint-which-changed',
          addedAt: DateTime.utc(2026, 1, 1),
        ),
      };

      var challengeCalled = false;
      final verifier = HostKeyVerifier(
        findKnownHost: (h, p) => store['$h:$p'],
        saveKnownHost: (kh) => store['${kh.host}:${kh.port}'] = kh,
      );

      expect(
        () => verifier.verify(
          host: 'server.com',
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprintBytes: fingerprintBytes,
          onChallenge: (challenge) async {
            challengeCalled = true;
            return true;
          },
        ),
        throwsA(
          isA<SSHHostKeyChangedException>()
              .having((e) => e.host, 'host', 'server.com')
              .having((e) => e.port, 'port', 22)
              .having((e) => e.expectedFingerprint, 'expected', 'SHA256:original-fingerprint-which-changed')
              .having((e) => e.presentedFingerprint, 'presented', expectedFp),
        ),
      );
      expect(challengeCalled, isFalse);
    });

    test('unknown host emits challenge; saves on accept and returns true', () async {
      final store = <String, KnownHost>{};
      final verifier = HostKeyVerifier(
        findKnownHost: (h, p) => store['$h:$p'],
        saveKnownHost: (kh) => store['${kh.host}:${kh.port}'] = kh,
      );

      var challenged = false;
      final result = await verifier.verify(
        host: 'new-server.com',
        port: 2222,
        keyType: 'ssh-ed25519',
        fingerprintBytes: fingerprintBytes,
        onChallenge: (challenge) async {
          challenged = true;
          expect(challenge.host, 'new-server.com');
          expect(challenge.port, 2222);
          expect(challenge.fingerprint, expectedFp);
          expect(challenge.keyType, 'ssh-ed25519');
          challenge.accept();
          return true;
        },
      );

      expect(result, isTrue);
      expect(challenged, isTrue);
      expect(store['new-server.com:2222'], isNotNull);
      expect(store['new-server.com:2222']!.fingerprint, expectedFp);
    });

    test('keeps the SHA256 text dartssh2 passes, as ssh-keygen prints it', () {
      const openSshText = 'SHA256:Q0ynKtbgRmoAoNdXUXjoMx9q+SQZX6WpGcyClsHHJBk';
      final bytes = Uint8List.fromList(utf8.encode(openSshText));
      expect(HostKeyVerifier.formatFingerprint(bytes), openSshText);
    });

    test('a key saved in the old double-encoded form still matches and is rewritten', () async {
      const openSshText = 'SHA256:Q0ynKtbgRmoAoNdXUXjoMx9q+SQZX6WpGcyClsHHJBk';
      final bytes = Uint8List.fromList(utf8.encode(openSshText));
      final legacy = 'SHA256:${base64.encode(bytes).replaceAll('=', '')}';
      final store = <String, KnownHost>{
        'server.com:22': KnownHost(
          host: 'server.com',
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprint: legacy,
          addedAt: DateTime.utc(2026, 1, 1),
        ),
      };
      final verifier = HostKeyVerifier(
        findKnownHost: (h, p) => store['$h:$p'],
        saveKnownHost: (kh) => store['${kh.host}:${kh.port}'] = kh,
      );

      final result = await verifier.verify(
        host: 'server.com',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprintBytes: bytes,
        onChallenge: (_) async => fail('A saved key must not prompt again.'),
      );

      expect(result, isTrue);
      expect(store['server.com:22']!.fingerprint, openSshText);
      expect(store['server.com:22']!.addedAt, DateTime.utc(2026, 1, 1));
    });

    test('unknown host emits challenge; does not save on reject and returns false', () async {
      final store = <String, KnownHost>{};
      final verifier = HostKeyVerifier(
        findKnownHost: (h, p) => store['$h:$p'],
        saveKnownHost: (kh) => store['${kh.host}:${kh.port}'] = kh,
      );

      var challenged = false;
      final result = await verifier.verify(
        host: 'new-server.com',
        port: 2222,
        keyType: 'ssh-ed25519',
        fingerprintBytes: fingerprintBytes,
        onChallenge: (challenge) async {
          challenged = true;
          challenge.reject();
          return false;
        },
      );

      expect(result, isFalse);
      expect(challenged, isTrue);
      expect(store['new-server.com:2222'], isNull);
    });
  });
}
