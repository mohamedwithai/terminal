import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/app.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/providers/session_tabs_providers.dart';
import 'package:ssh_app/providers/ssh_providers.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';
import 'package:ssh_app/services/vault_service.dart';
import 'package:xterm/xterm.dart';

import 'support/fake_terminal_session.dart';
import 'support/memory_stores.dart';

class _Controller extends SSHSessionController {
  _Controller({
    required super.ref,
    required super.sessionId,
    required super.server,
    required this.disconnected,
  });

  final List<String> disconnected;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {
    disconnected.add(sessionId);
  }
}

void main() {
  late MultiSessionService service;
  late Map<String, StreamController<SSHConnectionState>> states;
  late List<String> disconnected;
  late VaultService vault;

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    service = MultiSessionService();
    states = {};
    disconnected = [];
    vault = VaultService(
      secureStore: MemorySecureStore(),
      metadataStore: MemoryMetadataStore(),
    );
    for (final (id, label) in [('a', 'Alpha'), ('b', 'Bravo')]) {
      await vault.saveServer(
        ServerConfig.create(
          id: id,
          label: label,
          host: '$id.example.com',
          username: 'ada',
          authType: AuthType.password,
        ),
        const ServerCredentials(password: 'pw'),
      );
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          vaultServiceProvider.overrideWithValue(vault),
          sshConnectionServiceProvider.overrideWithValue(service),
          sshSessionStateProvider.overrideWith((ref, args) {
            return (states[args.sessionId] ??=
                    StreamController<SSHConnectionState>.broadcast())
                .stream;
          }),
          sshSessionControllerProvider.overrideWith((ref, args) {
            return _Controller(
              ref: ref,
              sessionId: args.sessionId,
              server: args.server,
              disconnected: disconnected,
            );
          }),
        ],
        child: const SshApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  ProviderContainer container(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(SshApp)));

  SessionTabsState tabs(WidgetTester tester) =>
      container(tester).read(sessionTabsProvider);

  /// Reports the active tab's session as connected, so its card goes away
  /// (a spinner would keep pumpAndSettle waiting).
  Future<void> connectActive(WidgetTester tester) async {
    await tester.pump();
    states[tabs(tester).activeId!]!.add(const SSHConnectionState.connected());
    await tester.pumpAndSettle();
  }

  Future<void> openHost(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).first);
    await connectActive(tester);
  }

  Terminal terminalOf(WidgetTester tester) =>
      tester.widget<TerminalView>(find.byType(TerminalView)).terminal;

  testWidgets('tapping a host opens a session tab in the workspace', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(tabs(tester).tabs, isEmpty);

    await openHost(tester, 'Alpha');

    expect(tabs(tester).count, 1);
    expect(tabs(tester).visible, isTrue);
    expect(find.byType(TerminalView), findsOneWidget);
    expect(
      find.byKey(ValueKey('tab-${tabs(tester).tabs.single.id}')),
      findsOneWidget,
    );
    // The bottom navigation gives way to the terminal.
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('Back goes to the hosts with the session still open', (
    tester,
  ) async {
    await pumpApp(tester);
    await openHost(tester, 'Alpha');
    final id = tabs(tester).tabs.single.id;
    states[id]!.add(const SSHConnectionState.connected());
    await tester.pump();
    terminalOf(tester).write('alpha-output');
    await tester.pump();

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tabs(tester).visible, isFalse);
    expect(tabs(tester).count, 1);
    expect(
      disconnected,
      isEmpty,
      reason: 'leaving the terminal is not disconnecting',
    );
    expect(find.text('ACTIVE NOW'), findsOneWidget);
    expect(find.text('1 tab'), findsOneWidget);

    // Tapping the host again returns to the same session, buffer intact.
    await openHost(tester, 'Alpha');
    expect(tabs(tester).count, 1);
    expect(tabs(tester).tabs.single.id, id);
    expect(terminalOf(tester).buffer.getText(), contains('alpha-output'));
  });

  testWidgets('the system back button also leaves the sessions open', (
    tester,
  ) async {
    await pumpApp(tester);
    await openHost(tester, 'Alpha');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(tabs(tester).visible, isFalse);
    expect(tabs(tester).count, 1);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('two hosts, two tabs, each keeps its own terminal', (
    tester,
  ) async {
    await pumpApp(tester);
    await openHost(tester, 'Alpha');
    terminalOf(tester).write('alpha-output');
    await tester.pump();

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await openHost(tester, 'Bravo');
    terminalOf(tester).write('bravo-output');
    await tester.pump();

    expect(tabs(tester).count, 2);
    expect(terminalOf(tester).buffer.getText(), contains('bravo-output'));
    expect(
      terminalOf(tester).buffer.getText(),
      isNot(contains('alpha-output')),
    );

    final first = tabs(tester).tabs.first;
    await tester.tap(find.byKey(ValueKey('tab-${first.id}')));
    await tester.pumpAndSettle();
    expect(tabs(tester).activeId, first.id);
    expect(terminalOf(tester).buffer.getText(), contains('alpha-output'));
    expect(
      terminalOf(tester).buffer.getText(),
      isNot(contains('bravo-output')),
    );

    await tester.tap(find.byKey(ValueKey('tab-${tabs(tester).tabs.last.id}')));
    await tester.pumpAndSettle();
    expect(terminalOf(tester).buffer.getText(), contains('bravo-output'));
  });

  testWidgets('the same host can be open twice, and the tabs are numbered', (
    tester,
  ) async {
    await pumpApp(tester);
    await openHost(tester, 'Alpha');

    await tester.tap(find.byKey(const ValueKey('new-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('new-session-a')));
    await connectActive(tester);

    expect(tabs(tester).count, 2);
    expect(tabs(tester).tabs.map((t) => t.server.id), ['a', 'a']);
    expect(tabs(tester).tabs.first.id, isNot(tabs(tester).tabs.last.id));
    expect(find.text('Alpha 1'), findsOneWidget);
    expect(find.text('Alpha 2'), findsOneWidget);
    // Different sessions: each has its own connection.
    expect(service.sessions.length, greaterThanOrEqualTo(2));
  });

  testWidgets('closing one tab ends that session and no other', (tester) async {
    await pumpApp(tester);
    await openHost(tester, 'Alpha');
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await openHost(tester, 'Bravo');
    final alpha = tabs(tester).tabs.first;
    final bravo = tabs(tester).tabs.last;
    for (final tab in [alpha, bravo]) {
      states[tab.id]!.add(const SSHConnectionState.connected());
    }
    await tester.pump();
    terminalOf(tester).write('bravo-output');

    // Close Alpha while Bravo is showing.
    await tester.tap(find.bySemanticsLabel('Close Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('Close this session?'), findsOneWidget);
    expect(
      find.textContaining('Your other sessions stay open'),
      findsOneWidget,
    );
    await tester.tap(find.text('Stay'));
    await tester.pumpAndSettle();
    expect(tabs(tester).count, 2);

    await tester.tap(find.bySemanticsLabel('Close Alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close session'));
    await tester.pumpAndSettle();

    expect(tabs(tester).tabs.map((t) => t.id), [bravo.id]);
    expect(tabs(tester).activeId, bravo.id);
    // Alpha's pane is gone; Bravo's is untouched and still has its output.
    expect(terminalOf(tester).buffer.getText(), contains('bravo-output'));
    expect(find.byType(TerminalView), findsOneWidget);
  });

  testWidgets(
    'closing the active tab shows its neighbour; the last one goes home',
    (tester) async {
      await pumpApp(tester);
      await openHost(tester, 'Alpha');
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await openHost(tester, 'Bravo');
      final alpha = tabs(tester).tabs.first;
      final bravo = tabs(tester).tabs.last;

      await tester.tap(find.bySemanticsLabel('Close Bravo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close session'));
      await tester.pumpAndSettle();
      expect(tabs(tester).tabs.map((t) => t.id), [alpha.id]);
      expect(tabs(tester).activeId, alpha.id);
      expect(tabs(tester).tabs.any((t) => t.id == bravo.id), isFalse);

      await tester.tap(find.bySemanticsLabel('Close Alpha'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close session'));
      await tester.pumpAndSettle();
      expect(tabs(tester).count, 0);
      expect(tabs(tester).visible, isFalse);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('ACTIVE NOW'), findsNothing);
    },
  );

  testWidgets('Disconnect in a tab\'s menu closes that tab only', (
    tester,
  ) async {
    await pumpApp(tester);
    await openHost(tester, 'Alpha');
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await openHost(tester, 'Bravo');
    final alpha = tabs(tester).tabs.first;
    final bravo = tabs(tester).tabs.last;
    states[bravo.id]!.add(const SSHConnectionState.connected());
    await tester.pump();

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Disconnect'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Disconnect'));
    await tester.pumpAndSettle();

    expect(disconnected, [bravo.id]);
    expect(tabs(tester).tabs.map((t) => t.id), [alpha.id]);
  });

  testWidgets('tabs show how each connection is doing', (tester) async {
    await pumpApp(tester);
    await openHost(tester, 'Alpha');
    final id = tabs(tester).tabs.single.id;

    states[id]!.add(const SSHConnectionState.connecting());
    await tester.pump();
    expect(tabs(tester).tabs.single.status, TabStatus.busy);

    states[id]!.add(const SSHConnectionState.connected());
    await tester.pump();
    expect(tabs(tester).tabs.single.status, TabStatus.connected);

    states[id]!.add(const SSHConnectionState.error('boom'));
    await tester.pump();
    expect(tabs(tester).tabs.single.status, TabStatus.problem);
  });

  testWidgets('only the open tab takes the keyboard and the volume keys', (
    tester,
  ) async {
    await pumpApp(tester);
    await openHost(tester, 'Alpha');
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await openHost(tester, 'Bravo');

    final panes = [
      for (final tab in tabs(tester).tabs)
        tester.widget<TerminalView>(
          find.descendant(
            of: find.byKey(ValueKey(tab.id), skipOffstage: false),
            matching: find.byType(TerminalView, skipOffstage: false),
          ),
        ),
    ];
    expect(panes[0].autofocus, isFalse);
    expect(panes[1].autofocus, isTrue);
  });

  testWidgets('deleting a host closes its sessions', (tester) async {
    await pumpApp(tester);
    await openHost(tester, 'Alpha');
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await openHost(tester, 'Bravo');
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(tabs(tester).count, 2);

    await tester.tap(find.byTooltip('Host options').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(tabs(tester).tabs.map((t) => t.server.id), ['b']);
  });

  testWidgets('"New session" in a host\'s menu opens a second tab', (
    tester,
  ) async {
    await pumpApp(tester);
    await openHost(tester, 'Alpha');
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Host options').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('New session'));
    await connectActive(tester);

    expect(tabs(tester).count, 2);
    expect(tabs(tester).tabs.map((t) => t.server.id), ['a', 'a']);
  });
}
