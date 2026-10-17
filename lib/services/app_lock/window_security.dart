import 'package:flutter/services.dart';

/// Hides the app in the recent-apps screen and blocks screenshots.
abstract interface class WindowSecurity {
  Future<void> setSecure(bool secure);
}

/// `FLAG_SECURE` on the Android window, set by `MainActivity`.
class AndroidWindowSecurity implements WindowSecurity {
  AndroidWindowSecurity({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'ssh_app/window';

  final MethodChannel _channel;

  @override
  Future<void> setSecure(bool secure) async {
    try {
      await _channel.invokeMethod<void>('setSecure', {'secure': secure});
    } on MissingPluginException {
      // Not running on Android.
    }
  }
}

class NoWindowSecurity implements WindowSecurity {
  const NoWindowSecurity();

  @override
  Future<void> setSecure(bool secure) async {}
}
