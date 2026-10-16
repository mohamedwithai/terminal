import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:ssh_app/services/network_monitor.dart';
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
class SessionKeeper {
  SessionKeeper({
    required this.connections,
    required this.foregroundService,
    required this.networkMonitor,
  });

  final SSHConnectionService connections;
  final SessionForegroundService foregroundService;
  final NetworkMonitor networkMonitor;

  AppLifecycleListener? _lifecycle;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  List<String> _shownLabels = const [];
  var _askedForPermission = false;

  ReconnectGate get _gate => connections.reconnectGate;

  void start() {
    _gate.foreground = isForeground(SchedulerBinding.instance.lifecycleState);
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) => _gate.foreground = isForeground(state),
    );

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
    }
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
  }
}
