import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/providers/preferences_providers.dart';
import 'package:ssh_app/providers/ssh_providers.dart';
import 'package:ssh_app/services/network_monitor.dart';
import 'package:ssh_app/services/session_foreground_service.dart';
import 'package:ssh_app/services/session_keeper.dart';

/// The Android foreground service that keeps sessions alive in the
/// background; a no-op elsewhere.
final sessionForegroundServiceProvider = Provider<SessionForegroundService>((
  ref,
) {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return const NoopSessionForegroundService();
  }
  final service = AndroidSessionForegroundService();
  ref.onDispose(service.dispose);
  return service;
});

final networkMonitorProvider = Provider<NetworkMonitor>((ref) {
  return ConnectivityNetworkMonitor();
});

/// Keeps sessions alive while the user is in another app. The app watches
/// this once at the top (see `SessionKeeperScope`).
final sessionKeeperProvider = Provider<SessionKeeper>((ref) {
  final keeper = SessionKeeper(
    connections: ref.watch(sshConnectionServiceProvider),
    foregroundService: ref.watch(sessionForegroundServiceProvider),
    networkMonitor: ref.watch(networkMonitorProvider),
    preferences: ref.watch(preferencesStoreProvider),
  )..start();
  ref.onDispose(keeper.dispose);
  return keeper;
});
