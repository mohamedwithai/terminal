import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/app.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/providers/session_keeper_providers.dart';
import 'package:ssh_app/services/network_monitor.dart';
import 'package:ssh_app/services/preferences_store.dart';
import 'package:ssh_app/services/session_foreground_service.dart';
import 'package:ssh_app/services/session_keeper.dart';
import 'package:ssh_app/services/ssh/ssh_connection_service.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';

import 'support/fake_ssh.dart';
import 'support/fake_terminal_session.dart';

void main() {
  final server = ServerConfig.create(
    id: 'srv-1',
    label: 'Build box',
    host: '10.0.0.1',
    username: 'ada',
    authType: AuthType.password,
  );

  ({
    SessionKeeper keeper,
    SSHConnectionService connections,
    _FakeForegroundService foreground,
    _FakeNetwork network,
  })
  setUpKeeper({
    bool online = true,
    bool permissionGranted = true,
    PreferencesStore? preferences,
  }) {
    final connections = SSHConnectionService(
      hostKeyVerifier: noKnownHosts(),
      socketFactory: FakeSSHSocketFactory(),
      reconnectDelays: const [Duration(hours: 1)],
    );
    final foreground = _FakeForegroundService()
      ..permissionGranted = permissionGranted;
    final network = _FakeNetwork(online);
    final keeper = SessionKeeper(
      connections: connections,
      foregroundService: foreground,
      networkMonitor: network,
      preferences: preferences ?? MemoryPreferencesStore(),
    )..start();
    addTearDown(() {
      keeper.dispose();
      connections.dispose();
      network.dispose();
      foreground.dispose();
    });
    return (
      keeper: keeper,
      connections: connections,
      foreground: foreground,
      network: network,
    );
  }

  testWidgets('the app lifecycle and the network drive the reconnect gate', (
    tester,
  ) async {
    final (:connections, :network, keeper: _, foreground: _) = setUpKeeper(
      online: false,
    );
    await tester.pump();
    final gate = connections.reconnectGate;
    expect(gate.online, isFalse);

    network.set(true);
    await tester.pump();
    expect(gate.online, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(gate.foreground, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(gate.foreground, isFalse);
    expect(gate.isOpen, isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(gate.isOpen, isTrue);
  });

  testWidgets('the foreground service runs while a session is active', (
    tester,
  ) async {
    final (:connections, :foreground, keeper: _, network: _) = setUpKeeper(
      online: false,
    );
    final session = connections.getOrCreateSession('session-1', server);
    await tester.pump();
    expect(foreground.updates, isEmpty);

    // A lost session waiting for the network still counts as active.
    session.debugSimulateConnectionLost(
      const ServerCredentials(password: 'secret'),
    );
    await tester.pump();
    expect(foreground.updates.last, ['Build box']);
    expect(foreground.permissionRequests, 1);

    await session.disconnect();
    await tester.pump();
    expect(foreground.updates.last, isEmpty);

    // Permission is asked for once per run, at the first connect.
    session.debugSimulateConnectionLost(
      const ServerCredentials(password: 'secret'),
    );
    await tester.pump();
    expect(foreground.updates.last, ['Build box']);
    expect(foreground.permissionRequests, 1);
  });

  testWidgets('Disconnect in the notification disconnects every session', (
    tester,
  ) async {
    final (:connections, :foreground, keeper: _, network: _) = setUpKeeper(
      online: false,
    );
    final first = connections.getOrCreateSession('session-1', server);
    final second = connections.getOrCreateSession('session-2', server);
    for (final session in [first, second]) {
      session.debugSimulateConnectionLost(
        const ServerCredentials(password: 'secret'),
      );
    }
    await tester.pump();
    expect(foreground.updates.last, ['Build box', 'Build box']);

    foreground.tapDisconnect();
    await tester.pump();

    expect(first.state.status, SSHConnectionStatus.disconnected);
    expect(second.state.status, SSHConnectionStatus.disconnected);
    expect(foreground.updates.last, isEmpty);
  });

  group('notifications off', () {
    testWidgets('denied permission gives one hint, once per install', (
      tester,
    ) async {
      final preferences = MemoryPreferencesStore();
      final (:keeper, :connections, foreground: _, network: _) = setUpKeeper(
        online: false,
        permissionGranted: false,
        preferences: preferences,
      );
      final hints = <void>[];
      keeper.notificationHints.listen(hints.add);

      final session = connections.getOrCreateSession('session-1', server);
      session.debugSimulateConnectionLost(
        const ServerCredentials(password: 'secret'),
      );
      await tester.pump();
      expect(hints, hasLength(1));
      expect(
        preferences.getBool(SessionKeeper.notificationHintShownKey),
        isTrue,
      );

      // The next run of the app asks again but does not repeat the hint.
      final (
        keeper: nextRun,
        connections: nextConnections,
        :foreground,
        network: _,
      ) = setUpKeeper(
        online: false,
        permissionGranted: false,
        preferences: preferences,
      );
      final nextHints = <void>[];
      nextRun.notificationHints.listen(nextHints.add);
      nextConnections
          .getOrCreateSession('session-1', server)
          .debugSimulateConnectionLost(
            const ServerCredentials(password: 'secret'),
          );
      await tester.pump();
      expect(foreground.permissionRequests, 1);
      expect(nextHints, isEmpty);
    });

    testWidgets('granted permission gives no hint', (tester) async {
      final (:keeper, :connections, foreground: _, network: _) = setUpKeeper(
        online: false,
      );
      final hints = <void>[];
      keeper.notificationHints.listen(hints.add);

      connections
          .getOrCreateSession('session-1', server)
          .debugSimulateConnectionLost(
            const ServerCredentials(password: 'secret'),
          );
      await tester.pump();
      expect(hints, isEmpty);
    });

    testWidgets('coming back from the settings posts the notification again', (
      tester,
    ) async {
      final (:connections, :foreground, keeper: _, network: _) = setUpKeeper(
        online: false,
        permissionGranted: false,
      );
      connections
          .getOrCreateSession('session-1', server)
          .debugSimulateConnectionLost(
            const ServerCredentials(password: 'secret'),
          );
      await tester.pump();
      final posted = foreground.updates.length;

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(foreground.updates, hasLength(posted + 1));
      expect(foreground.updates.last, ['Build box']);
    });

    testWidgets('the hint shows on screen and opens the settings', (
      tester,
    ) async {
      final (:keeper, :connections, :foreground, network: _) = setUpKeeper(
        online: false,
        permissionGranted: false,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionKeeperProvider.overrideWithValue(keeper),
            sessionForegroundServiceProvider.overrideWithValue(foreground),
          ],
          child: SessionKeeperScope(
            child: MaterialApp(
              scaffoldMessengerKey: rootScaffoldMessengerKey,
              home: const Scaffold(body: Text('terminal')),
            ),
          ),
        ),
      );

      connections
          .getOrCreateSession('session-1', server)
          .debugSimulateConnectionLost(
            const ServerCredentials(password: 'secret'),
          );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Notifications are off. Your session may disconnect when you '
          'switch apps.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      expect(foreground.settingsOpened, 1);
    });
  });
}

class _FakeForegroundService implements SessionForegroundService {
  final updates = <List<String>>[];
  var permissionRequests = 0;
  var permissionGranted = true;
  var settingsOpened = 0;
  final _disconnects = StreamController<void>.broadcast();

  void tapDisconnect() => _disconnects.add(null);

  @override
  Future<void> openNotificationSettings() async {
    settingsOpened++;
  }

  @override
  Future<void> notify(String title, String text) async {}

  @override
  Future<void> update(List<String> sessionLabels) async {
    updates.add(sessionLabels);
  }

  @override
  Future<bool> requestNotificationPermission() async {
    permissionRequests++;
    return permissionGranted;
  }

  @override
  Stream<void> get disconnectRequests => _disconnects.stream;

  void dispose() => _disconnects.close();
}

class _FakeNetwork implements NetworkMonitor {
  _FakeNetwork(this._online);

  bool _online;
  final _changes = StreamController<bool>.broadcast();

  void set(bool online) {
    _online = online;
    _changes.add(online);
  }

  @override
  Future<bool> isOnline() async => _online;

  @override
  Stream<bool> get onlineChanges => _changes.stream;

  void dispose() => _changes.close();
}
