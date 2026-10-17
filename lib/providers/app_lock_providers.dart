import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/app_settings.dart';
import 'package:ssh_app/providers/preferences_providers.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/services/app_lock/biometric_authenticator.dart';
import 'package:ssh_app/services/app_lock/pin_store.dart';
import 'package:ssh_app/services/app_lock/window_security.dart';

final pinStoreProvider = Provider<PinStore>((ref) {
  return PinStore(ref.watch(secureStoreProvider));
});

final biometricAuthenticatorProvider = Provider<BiometricAuthenticator>((ref) {
  return kIsWeb ? const NoBiometrics() : LocalAuthBiometrics();
});

final windowSecurityProvider = Provider<WindowSecurity>((ref) {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return const NoWindowSecurity();
  }
  return AndroidWindowSecurity();
});

/// Whether the app is locked, and for how long a PIN cannot be tried.
class AppLockState {
  const AppLockState({this.locked = false, this.lockedOutFor});

  final bool locked;
  final Duration? lockedOutFor;
}

final appLockProvider = NotifierProvider<AppLockController, AppLockState>(
  AppLockController.new,
);

/// Decides when the app locks and unlocks it.
///
/// It starts locked when the lock is on, and locks again once the app has
/// been out of the foreground for the chosen time. It never locks while a
/// fingerprint prompt is up or while the app has handed over to the file
/// picker or share sheet ([runExternal]), both of which pause the app.
class AppLockController extends Notifier<AppLockState> {
  DateTime Function() clock = DateTime.now;
  DateTime? _backgroundedAt;
  var _external = 0;
  var _authenticating = false;

  bool get _enabled => ref.read(appSettingsProvider).appLock;

  @override
  AppLockState build() {
    ref.listen(appSettingsProvider.select((s) => s.appLock), (previous, now) {
      // Turning the lock off opens the app; turning it on does not lock the
      // person who just set it up.
      if (!now) state = const AppLockState();
    });
    final enabled = ref.read(appSettingsProvider).appLock;
    if (enabled) {
      unawaited(_dropLockIfPinIsGone());
    }
    return AppLockState(locked: enabled);
  }

  /// A lock without a PIN could never be opened, for example after the
  /// secure storage was cleared. Turn it off instead of trapping the user.
  Future<void> _dropLockIfPinIsGone() async {
    try {
      if (!await ref.read(pinStoreProvider).hasPin()) {
        await ref
            .read(appSettingsProvider.notifier)
            .update((s) => s.copyWith(appLock: false, lockBiometrics: false));
        state = const AppLockState();
      }
    } catch (error) {
      debugPrint('Could not check the app lock PIN: $error');
    }
  }

  /// Feed the app's lifecycle here.
  void onLifecycle(AppLifecycleState lifecycle) {
    if (!_enabled || _authenticating || _external > 0) return;
    switch (lifecycle) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        _backgroundedAt ??= clock();
        if (ref.read(appSettingsProvider).lockTimeout ==
            LockTimeout.immediately) {
          _lock();
        }
      case AppLifecycleState.resumed:
        final since = _backgroundedAt;
        _backgroundedAt = null;
        if (since != null &&
            clock().difference(since) >=
                ref.read(appSettingsProvider).lockTimeout.duration) {
          _lock();
        }
      default:
        break;
    }
  }

  void _lock() {
    if (!state.locked) state = const AppLockState(locked: true);
  }

  /// Locks now, from a menu.
  void lockNow() {
    if (_enabled) _lock();
  }

  /// Runs [action], which leaves the app for another screen (a file picker,
  /// the share sheet), without that counting as leaving the app.
  Future<T> runExternal<T>(Future<T> Function() action) async {
    _external++;
    try {
      return await action();
    } finally {
      _external--;
      _backgroundedAt = null;
    }
  }

  /// Checks [pin]. On success the app unlocks.
  Future<PinResult> unlockWithPin(String pin) async {
    final result = await ref.read(pinStoreProvider).verify(pin);
    switch (result) {
      case PinCorrect():
        _backgroundedAt = null;
        state = const AppLockState();
      case PinWrong(:final lockedFor):
        state = AppLockState(locked: true, lockedOutFor: lockedFor);
      case PinLockedOut(:final remaining):
        state = AppLockState(locked: true, lockedOutFor: remaining);
    }
    return result;
  }

  /// Asks for fingerprint or face. On success the app unlocks.
  Future<bool> unlockWithBiometrics() async {
    if (!ref.read(appSettingsProvider).lockBiometrics || _authenticating) {
      return false;
    }
    _authenticating = true;
    try {
      final ok = await ref
          .read(biometricAuthenticatorProvider)
          .authenticate('Unlock SSH');
      if (ok) {
        _backgroundedAt = null;
        state = const AppLockState();
      }
      return ok;
    } finally {
      _authenticating = false;
    }
  }
}
