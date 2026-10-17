import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

/// Fingerprint or face unlock.
abstract interface class BiometricAuthenticator {
  /// Whether this device has biometrics set up.
  Future<bool> isAvailable();

  /// Asks the user to authenticate. False if they cancel or it fails.
  Future<bool> authenticate(String reason);

  /// Cancels a prompt that is showing.
  Future<void> cancel();
}

/// Biometrics only: the PIN is the app's own fallback, so the phone's screen
/// lock is not accepted instead.
class LocalAuthBiometrics implements BiometricAuthenticator {
  LocalAuthBiometrics({LocalAuthentication? auth})
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> isAvailable() async {
    if (kIsWeb) return false;
    try {
      if (!await _auth.isDeviceSupported() || !await _auth.canCheckBiometrics) {
        return false;
      }
      return (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } on LocalAuthException {
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _auth.stopAuthentication();
    } catch (_) {
      // Nothing to cancel.
    }
  }
}

/// For platforms and tests without biometrics.
class NoBiometrics implements BiometricAuthenticator {
  const NoBiometrics();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<bool> authenticate(String reason) async => false;

  @override
  Future<void> cancel() async {}
}
