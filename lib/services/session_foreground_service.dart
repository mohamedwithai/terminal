import 'dart:async';

import 'package:flutter/services.dart';

/// Keeps the app running while SSH sessions are open.
///
/// On Android this is a foreground service with a persistent notification.
/// Without one, Android cuts the network of an app in the background or
/// freezes it, and its SSH connections drop as soon as the user switches
/// apps.
abstract interface class SessionForegroundService {
  /// Shows the notification for the active sessions, named by
  /// [sessionLabels], or stops the service when there are none.
  Future<void> update(List<String> sessionLabels);

  /// Asks for permission to show notifications, which Android 13 and later
  /// need. Returns whether it is granted.
  Future<bool> requestNotificationPermission();

  /// Opens the system settings where the user can turn this app's
  /// notifications back on.
  Future<void> openNotificationSettings();

  /// Emits when the user taps Disconnect in the notification.
  Stream<void> get disconnectRequests;
}

/// For platforms that keep the app's connections in the background on their
/// own, or where there is nothing to keep.
class NoopSessionForegroundService implements SessionForegroundService {
  const NoopSessionForegroundService();

  @override
  Future<void> update(List<String> sessionLabels) async {}

  @override
  Future<bool> requestNotificationPermission() async => true;

  @override
  Future<void> openNotificationSettings() async {}

  @override
  Stream<void> get disconnectRequests => const Stream.empty();
}

/// Talks to `SessionForegroundService` in the Android app over a method
/// channel.
class AndroidSessionForegroundService implements SessionForegroundService {
  AndroidSessionForegroundService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_handleCall);
  }

  static const channelName = 'ssh_app/session_foreground_service';

  final MethodChannel _channel;
  final _disconnectRequests = StreamController<void>.broadcast();

  Future<Object?> _handleCall(MethodCall call) async {
    if (call.method == 'disconnectAll') {
      _disconnectRequests.add(null);
    }
    return null;
  }

  @override
  Future<void> update(List<String> sessionLabels) {
    return _channel.invokeMethod<void>('update', {'labels': sessionLabels});
  }

  @override
  Future<bool> requestNotificationPermission() async {
    return await _channel.invokeMethod<bool>('requestNotificationPermission') ??
        false;
  }

  @override
  Future<void> openNotificationSettings() {
    return _channel.invokeMethod<void>('openNotificationSettings');
  }

  @override
  Stream<void> get disconnectRequests => _disconnectRequests.stream;

  void dispose() {
    _channel.setMethodCallHandler(null);
    _disconnectRequests.close();
  }
}
