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

  /// Returns the OpenSSH fingerprint `SHA256:<base64-no-padding>`, the same
  /// text `ssh-keygen -lf` prints.
  ///
  /// dartssh2 4 already passes that text, UTF-8 encoded, to
  /// `onVerifyHostKey`; it is returned unchanged. A raw SHA-256 digest is
  /// encoded into that form.
  static String formatFingerprint(Uint8List fingerprintBytes) {
    final text = _fingerprintText(fingerprintBytes);
    if (text != null) {
      return text;
    }
    return _encodeDigest(fingerprintBytes);
  }

  static String? _fingerprintText(Uint8List bytes) {
    try {
      final text = utf8.decode(bytes);
      return text.startsWith('SHA256:') ? text : null;
    } on FormatException {
      return null;
    }
  }

  static String _encodeDigest(Uint8List bytes) {
    return 'SHA256:${base64.encode(bytes).replaceAll('=', '')}';
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
      // Earlier builds base64-encoded dartssh2's fingerprint text a second
      // time before saving it. That encoding is one-to-one, so a match still
      // means the same key; store it again in the readable form.
      if (existing.fingerprint == _encodeDigest(fingerprintBytes)) {
        await saveKnownHost(
          KnownHost(
            host: existing.host,
            port: existing.port,
            keyType: existing.keyType,
            fingerprint: fingerprint,
            addedAt: existing.addedAt,
          ),
        );
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
