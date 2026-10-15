import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ssh_app/models/known_host.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';
import 'package:ssh_app/services/ssh/ssh_errors.dart';

typedef KnownHostLookup = FutureOr<KnownHost?> Function(String host, int port);
typedef KnownHostSaver = FutureOr<void> Function(KnownHost host);
typedef ChallengeHandler = Future<bool> Function(HostKeyChallenge challenge);

/// Trust-on-first-use (TOFU) host key verification logic.
class HostKeyVerifier {
  const HostKeyVerifier({
    required this.findKnownHost,
    required this.saveKnownHost,
  });

  final KnownHostLookup findKnownHost;
  final KnownHostSaver saveKnownHost;

  /// Formats raw SHA-256 digest bytes into standard OpenSSH fingerprint format: `SHA256:<base64-no-padding>`.
  static String formatFingerprint(Uint8List fingerprintBytes) {
    return 'SHA256:${base64.encode(fingerprintBytes).replaceAll('=', '')}';
  }

  /// Verifies a presented host key against the known hosts store.
  ///
  /// - Known host with matching fingerprint -> returns true.
  /// - Known host with CHANGED fingerprint -> throws [SSHHostKeyChangedException] (hard error).
  /// - Unknown host -> creates a challenge, calls [onChallenge]. If accepted, saves to store and returns true.
  Future<bool> verify({
    required String host,
    required int port,
    required String keyType,
    required Uint8List fingerprintBytes,
    required ChallengeHandler onChallenge,
  }) async {
    final fingerprint = formatFingerprint(fingerprintBytes);
    final existing = await findKnownHost(host, port);

    if (existing != null) {
      if (existing.fingerprint == fingerprint) {
        return true;
      }
      // CHANGED FINGERPRINT: Under TOFU, this is a hard error that must never be auto-accepted.
      throw SSHHostKeyChangedException(
        host: host,
        port: port,
        expectedFingerprint: existing.fingerprint,
        presentedFingerprint: fingerprint,
        keyType: keyType,
      );
    }

    // UNKNOWN HOST: Request explicit user confirmation.
    final completer = Completer<bool>();
    final challenge = HostKeyChallenge(
      host: host,
      port: port,
      keyType: keyType,
      fingerprint: fingerprint,
      completer: completer,
    );

    final accepted = await onChallenge(challenge);

    if (accepted) {
      final newKnownHost = KnownHost(
        host: host,
        port: port,
        keyType: keyType,
        fingerprint: fingerprint,
        addedAt: DateTime.now().toUtc(),
      );
      await saveKnownHost(newKnownHost);
      return true;
    } else {
      return false;
    }
  }
}
