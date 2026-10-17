import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/providers/autocomplete_providers.dart';
import 'package:ssh_app/providers/preferences_providers.dart';
import 'package:ssh_app/providers/ssh_providers.dart';
import 'package:ssh_app/screens/settings_screen.dart';
import 'package:ssh_app/screens/terminal_screen.dart';
import 'package:ssh_app/services/autocomplete/history.dart';
import 'package:ssh_app/services/preferences_store.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';
import 'package:xterm/xterm.dart';

import 'support/fake_terminal_session.dart';

void main() {
  final server = ServerConfig.create(
    id: 'srv-1',
    label: 'Build box',
    host: 'example.com',
    username: 'ada',
    authType: AuthType.password,
  );
  final now = DateTime.now().toUtc();

  late RecordingSession session;
  late MemoryHistoryStore store;
  late StreamController<SSHConnectionState> states;

  Future<Terminal> pumpTerminal(
    WidgetTester tester, {
    bool autocomplete = true,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final prefs = MemoryPreferencesStore();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sshConnectionServiceProvider.overrideWithValue(
            SingleSessionService(session),
          ),
          sshSessionStateProvider.overrideWith((ref, args) => states.stream),
          historyStoreProvider.overrideWithValue(store),
          preferencesStoreProvider.overrideWithValue(prefs),
        ],
        child: MaterialApp(
          home: TerminalScreen(
            server: server,
            sessionId: 'session-1',
            autoConnect: false,
          ),
        ),
      ),
    );
    await tester.pump();
    if (!autocomplete) {
      final container = ProviderScope.containerOf(
        tester.element(find.byType(TerminalScreen)),
      );
      await container
          .read(appSettingsProvider.notifier)
          .update((s) => s.copyWith(autocomplete: false));
    }
    states.add(const SSHConnectionState.connected());
    await tester.pump();
    await tester.pump();
    session.writes.clear();
    return tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
  }

  /// The shell's prompt, as the integration script prints it.
  void prompt(Terminal terminal) {
    terminal.write('\x1b]133;A\x07\$ \x1b]133;B\x07');
  }

  Future<void> settle(WidgetTester tester) async {
    // The debounce, then the panel's 180ms fade.
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 250));
  }

  HistoryEntry entry(String command, int count, Duration ago) =>
      HistoryEntry(command: command, count: count, lastUsed: now.subtract(ago));

  setUp(() {
    session = RecordingSession(server)..connected = true;
    store = MemoryHistoryStore();
    states = StreamController<SSHConnectionState>.broadcast();
  });
  tearDown(() => states.close());

  testWidgets('with shell integration the line is read off the screen', (
    tester,
  ) async {
    store.data['srv-1'] = [
      entry('git pull --rebase', 14, const Duration(hours: 2)),
      entry('git push', 5, const Duration(hours: 1)),
    ];
    final terminal = await pumpTerminal(tester);

    prompt(terminal);
    terminal.write('git p');
    await settle(tester);

    expect(find.byKey(const ValueKey('suggestion-0')), findsOneWidget);
    expect(find.textContaining('14x, last 2h ago'), findsOneWidget);
    // The first one is also the grey text after the cursor.
    final ghost = tester.widget<Text>(find.byKey(const ValueKey('ghost-text')));
    expect(ghost.data, 'ull --rebase');
    // Nothing was sent to the shell by merely suggesting.
    expect(session.writes, isEmpty);
  });

  testWidgets(
    'tap fills, long press fills and runs, right arrow takes the ghost',
    (tester) async {
      store.data['srv-1'] = [
        entry('git pull --rebase', 14, const Duration(hours: 2)),
      ];
      final terminal = await pumpTerminal(tester);
      prompt(terminal);
      terminal.write('git p');
      await settle(tester);

      await tester.tap(find.byKey(const ValueKey('suggestion-0')));
      await tester.pump();
      expect(session.written, 'ull --rebase');
      expect(session.written, isNot(contains('\r')));

      // Same suggestion, long press: fills and presses Enter.
      session.writes.clear();
      await tester.longPress(find.byKey(const ValueKey('suggestion-0')));
      await tester.pump();
      expect(session.written, 'ull --rebase\r');

      // A new prompt, and the right arrow key takes the grey text instead
      // of moving the cursor.
      prompt(terminal);
      terminal.write('git p');
      await settle(tester);
      session.writes.clear();
      await tester.tap(find.byTooltip('Right'));
      await tester.pump();
      expect(session.written, 'ull --rebase');
    },
  );

  testWidgets('without the integration it follows the keys typed', (
    tester,
  ) async {
    store.data['srv-1'] = [entry('docker ps -a', 3, const Duration(hours: 1))];
    final terminal = await pumpTerminal(tester);

    terminal.textInput('docker p');
    await settle(tester);

    expect(find.byKey(const ValueKey('suggestion-0')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('ghost-text'))).data,
      's -a',
    );

    // An arrow key makes the line unknown, so suggestions stop.
    terminal.keyInput(TerminalKey.arrowUp);
    await settle(tester);
    expect(find.byKey(const ValueKey('suggestion-0')), findsNothing);

    // Ctrl+C starts clean.
    terminal.textInput('\x03');
    terminal.textInput('docker p');
    await settle(tester);
    expect(find.byKey(const ValueKey('suggestion-0')), findsOneWidget);
  });

  testWidgets(
    'a full-screen program or a running command gets no suggestions',
    (tester) async {
      store.data['srv-1'] = [entry('git status', 3, const Duration(hours: 1))];
      final terminal = await pumpTerminal(tester);
      prompt(terminal);
      terminal.write('git s');
      await settle(tester);
      expect(find.byKey(const ValueKey('suggestion-0')), findsOneWidget);

      // Enter starts the command; its output is not a line to complete.
      terminal.textInput('\r');
      terminal.write('\r\nrunning...\r\ngit s');
      await settle(tester);
      expect(find.byKey(const ValueKey('suggestion-0')), findsNothing);

      // A new prompt brings them back; vim's screen does not.
      prompt(terminal);
      terminal.write('git s');
      await settle(tester);
      expect(find.byKey(const ValueKey('suggestion-0')), findsOneWidget);
      terminal.write('\x1b[?1049h');
      await settle(tester);
      expect(find.byKey(const ValueKey('suggestion-0')), findsNothing);
    },
  );

  testWidgets('the setting turns suggestions off', (tester) async {
    store.data['srv-1'] = [entry('git status', 3, const Duration(hours: 1))];
    final terminal = await pumpTerminal(tester, autocomplete: false);
    prompt(terminal);
    terminal.write('git s');
    await settle(tester);
    expect(find.byKey(const ValueKey('suggestion-0')), findsNothing);
    expect(find.byKey(const ValueKey('ghost-text')), findsNothing);
  });

  group('history', () {
    testWidgets('a command is kept when it ends with exit code 0', (
      tester,
    ) async {
      final terminal = await pumpTerminal(tester);
      prompt(terminal);
      terminal.write('ls -la');
      terminal.textInput('\r');
      terminal.write('\r\nfile\r\n\x1b]133;D;0\x07');
      await settle(tester);

      expect(store.data['srv-1']?.map((e) => e.command), ['ls -la']);

      // One that failed is not.
      prompt(terminal);
      terminal.write('lss');
      terminal.textInput('\r');
      terminal.write('\r\nnot found\r\n\x1b]133;D;127\x07');
      await settle(tester);
      expect(store.data['srv-1']!.map((e) => e.command), ['ls -la']);
    });

    testWidgets('without the integration it is kept on Enter', (tester) async {
      final terminal = await pumpTerminal(tester);
      terminal.textInput('uptime');
      terminal.textInput('\r');
      await settle(tester);

      expect(store.data['srv-1']?.map((e) => e.command), ['uptime']);
    });

    testWidgets(
      'sensitive lines and lines starting with a space are not kept',
      (tester) async {
        final terminal = await pumpTerminal(tester);
        for (final command in [
          ' hidden',
          'mysql --password=hunter2',
          'export API_KEY=abc',
          'ls',
        ]) {
          terminal.textInput('$command\r');
        }
        await settle(tester);

        expect(store.data['srv-1']!.map((e) => e.command), ['ls']);
      },
    );

    testWidgets('what is typed at a password prompt is never kept', (
      tester,
    ) async {
      final terminal = await pumpTerminal(tester);
      terminal.write('[sudo] password for ada: ');
      terminal.textInput('correcthorse\r');
      await settle(tester);
      expect(store.data['srv-1'], isNull);

      // Same with the integration on: the answer is not at the shell prompt.
      prompt(terminal);
      terminal.write('sudo ls');
      terminal.textInput('\r');
      terminal.write('\r\n[sudo] password for ada: ');
      terminal.textInput('correcthorse\r');
      terminal.write('\r\nfile\r\n\x1b]133;D;0\x07');
      await settle(tester);
      expect(store.data['srv-1']!.map((e) => e.command), ['sudo ls']);
    });
  });

  testWidgets('settings: clear history for one host', (tester) async {
    store.data['srv-1'] = [entry('git status', 3, const Duration(hours: 1))];
    store.data['srv-2'] = [entry('df -h', 1, const Duration(hours: 1))];
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [historyStoreProvider.overrideWithValue(store)],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('clear-history')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('clear-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('clear-history')));
    await tester.pumpAndSettle();
    expect(find.text('1 commands'), findsNWidgets(2));

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('history-srv-1')),
        matching: find.text('Clear'),
      ),
    );
    await tester.pumpAndSettle();
    expect(store.data.containsKey('srv-1'), isFalse);
    expect(store.data['srv-2'], isNotEmpty);
    expect(find.byKey(const ValueKey('history-srv-1')), findsNothing);
  });
}
