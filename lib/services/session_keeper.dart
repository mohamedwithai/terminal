import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:ssh_app/services/network_monitor.dart';
import 'package:ssh_app/services/preferences_store.dart';
import 'package:ssh_app/services/session_foreground_service.dart';
import 'package:ssh_app/services/ssh/reconnect_gate.dart';
import 'package:ssh_app/services/ssh/ssh_connection_service.dart';

/// Keeps SSH sessions alive while the user is in another app.
///
/// - Feeds the app's foreground state and the network state into the
///   [ReconnectGate], so a lost session waits for both instead of spending
///   its reconnect attempts.
/// - Runs the [SessionForegroundService] while any session is active, asks
///   for notification permission at the first connect, and disconnects every
///   session when the notification's Disconnect is tapped.
/// - If notifications are denied, emits one [notificationHints] event, once
///   per install, so the UI can explain and offer the settings.
class SessionKeeper {
  SessionKeeper({
    required this.connections,
    required this.foregroundService,
    required this.networkMonitor,
    required this.preferences,
  });

  /// Set once the notifications-off hint has been shown.
  static const notificationHintShownKey = 'notification_hint_shown';

  final SSHConnectionService connections;
  final SessionForegroundService foregroundService;
  final NetworkMonitor networkMonitor;
  final PreferencesStore preferences;

  AppLifecycleListener? _lifecycle;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  final _notificationHints = StreamController<void>.broadcast();
  List<String> _shownLabels = const [];
  var _askedForPermission = false;
  var _notificationsDenied = false;

  /// Emits when the UI should say that notifications are off and sessions
  /// may drop in the background.
  Stream<void> get notificationHints => _notificationHints.stream;

  ReconnectGate get _gate => connections.reconnectGate;

  void start() {
    _gate.foreground = isForeground(SchedulerBinding.instance.lifecycleState);
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycleChanged);

    unawaited(_checkNetwork());
    _subscriptions.add(
      networkMonitor.onlineChanges.listen(
        (online) => _gate.online = online,
        onError: (Object error) => _gate.online = true,
      ),
    );

    _subscriptions.add(
      connections.changes.listen((_) => unawaited(_syncForegroundService())),
    );
    _subscriptions.add(
      foregroundService.disconnectRequests.listen(
        (_) => unawaited(connections.disconnectAll()),
      ),
    );
    unawaited(_syncForegroundService());
  }

  /// Resumed and inactive (a permission dialog or the notification shade on
  /// top) count as foreground; hidden and paused do not.
  @visibleForTesting
  static bool isForeground(AppLifecycleState? state) {
    return switch (state) {
      null || AppLifecycleState.resumed || AppLifecycleState.inactive => true,
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached => false,
    };
  }

  void _onLifecycleChanged(AppLifecycleState state) {
    _gate.foreground = isForeground(state);
    if (state == AppLifecycleState.resumed &&
        _notificationsDenied &&
        _shownLabels.isNotEmpty) {
      // The user may have turned notifications on in the settings. The
      // notification posted while they were off stays hidden, so post it
      // again.
      unawaited(_update(_shownLabels));
    }
  }

  Future<void> _checkNetwork() async {
    try {
      _gate.online = await networkMonitor.isOnline();
    } catch (error) {
      // Without a reliable answer, keep reconnecting rather than wait forever.
      debugPrint('Could not read the network state: $error');
      _gate.online = true;
    }
  }

  Future<void> _syncForegroundService() async {
    final labels = [
      for (final session in connections.activeSessions) session.server.label,
    ];
    if (listEquals(labels, _shownLabels)) {
      return;
    }
    final firstConnect = _shownLabels.isEmpty && labels.isNotEmpty;
    _shownLabels = labels;
    await _update(labels);

    if (firstConnect && !_askedForPermission) {
      _askedForPermission = true;
      final bool granted;
      try {
        granted = await foregroundService.requestNotificationPermission();
      } catch (error) {
        debugPrint('Could not ask for notification permission: $error');
        return;
      }
      // A notification posted before permission was granted stays hidden.
      if (granted && _shownLabels.isNotEmpty) {
        await _update(_shownLabels);
      }
      if (!granted) {
        _notificationsDenied = true;
        _hintOnce();
      }
    }
  }

  void _hintOnce() {
    if (preferences.getBool(notificationHintShownKey) ||
        _notificationHints.isClosed) {
      return;
    }
    unawaited(preferences.setBool(notificationHintShownKey, true));
    _notificationHints.add(null);
  }

  Future<void> _update(List<String> labels) async {
    try {
      await foregroundService.update(labels);
    } catch (error) {
      debugPrint('Could not update the session notification: $error');
    }
  }

  void dispose() {
    _lifecycle?.dispose();
    _lifecycle = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _notificationHints.close();
  }
}
