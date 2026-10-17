import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/snippet.dart';
import 'package:ssh_app/providers/snippet_providers.dart';
import 'package:ssh_app/providers/ssh_providers.dart';
import 'package:ssh_app/screens/terminal_screen.dart';
import 'package:ssh_app/services/snippet_store.dart';
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

  late RecordingSession session;
  late MemorySnippetStore store;
  late StreamController<SSHConnectionState> states;

  Future<void> pumpTerminal(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sshConnectionServiceProvider.overrideWithValue(
            SingleSessionService(session),
          ),
          sshSessionStateProvider.overrideWith((ref, args) => states.stream),
          snippetStoreProvider.overrideWithValue(store),
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
  }

  /// The shell opens once the session reports connected.
  Future<FakeShell> connect(WidgetTester tester) async {
    states.add(const SSHConnectionState.connected());
    await tester.pump();
    await tester.pump();
    return session.shells.last;
  }

  /// Plays the shell's part for the last command written: echo it, then
  /// print the exit-code marker it asked for.
  void finishLastCommand(FakeShell shell, {int code = 0}) {
    final line = session.written.split('\r').where((l) => l.isNotEmpty).last;
    final marker = RegExp(r'__RC_(\w+)=').firstMatch(line);
    shell.emit('$line\r\n');
    if (marker != null) shell.emit('__RC_${marker.group(1)}=$code\r\n');
  }

  String screen(WidgetTester tester) => tester
      .widget<TerminalView>(find.byType(TerminalView))
      .terminal
      .buffer
      .getText();

  setUp(() {
    session = RecordingSession(server)..connected = true;
    store = MemorySnippetStore();
    states = StreamController<SSHConnectionState>.broadcast();
  });
  tearDown(() => states.close());

  testWidgets('the snippet button runs a picked snippet and hides the marker', (
    tester,
  ) async {
    await store.put(
      Snippet.create(
        name: 'Disk usage',
        steps: const [SnippetStep(command: 'df -h')],
      ),
    );
    await pumpTerminal(tester);
    final shell = await connect(tester);

    await tester.tap(find.byTooltip('Snippets').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disk usage'));
    await tester.pump();
    await tester.pump();

    expect(session.written, matches(RegExp(r'^df -h;echo __RC_\w{6}=\$\?\r$')));
    expect(find.byKey(const ValueKey('snippet-banner')), findsOneWidget);

    finishLastCommand(shell);
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('snippet-banner')), findsNothing);
    final text = screen(tester);
    expect(text, contains('df -h'));
    expect(text, isNot(contains('__RC_')));
  });

  testWidgets(
    'a snippet with variables asks for them and runs the filled commands',
    (tester) async {
      await store.put(
        Snippet.create(
          name: 'Restart',
          steps: const [SnippetStep(command: r'systemctl restart ${SVC}')],
          variables: const [
            SnippetVariable(
              name: 'SVC',
              type: VariableType.choice,
              choices: ['nginx', 'redis'],
            ),
          ],
        ),
      );
      await pumpTerminal(tester);
      await connect(tester);

      await tester.tap(find.byTooltip('Snippets').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restart'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('var-SVC')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('redis').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Run'));
      await tester.pump();
      await tester.pump();

      expect(session.written, startsWith('systemctl restart redis;echo __RC_'));
    },
  );

  testWidgets('stop at first failure shows which step failed', (tester) async {
    await store.put(
      Snippet.create(
        name: 'Build',
        steps: const [
          SnippetStep(command: 'make'),
          SnippetStep(command: 'make install'),
        ],
        stopOnFailure: true,
      ),
    );
    await pumpTerminal(tester);
    final shell = await connect(tester);
    await tester.tap(find.byTooltip('Snippets').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Build'));
    await tester.pump();
    await tester.pump();

    finishLastCommand(shell, code: 2);
    await tester.pump();
    await tester.pump();

    expect(find.text('"Build" failed at step 1.'), findsOneWidget);
    expect(session.written, isNot(contains('make install')));
  });

  testWidgets('Stop abandons a run in progress', (tester) async {
    await store.put(
      Snippet.create(
        name: 'Long',
        steps: const [
          SnippetStep(command: 'sleep 99'),
          SnippetStep(command: 'next'),
        ],
      ),
    );
    await pumpTerminal(tester);
    await connect(tester);
    await tester.tap(find.byTooltip('Snippets').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Long'));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('Stop'));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('snippet-banner')), findsNothing);
    expect(session.written, isNot(contains('next')));
  });

  group('on connect', () {
    testWidgets('runs for this host, each time a shell opens', (tester) async {
      await store.put(
        Snippet.create(
          name: 'Attach',
          steps: const [SnippetStep(command: 'tmux new -A -s main')],
        ).copyWith(runOnConnect: [server.id]),
      );
      await store.put(
        Snippet.create(
          name: 'Other host',
          steps: const [SnippetStep(command: 'echo other')],
        ).copyWith(runOnConnect: ['someone-else']),
      );
      await pumpTerminal(tester);

      final first = await connect(tester);
      await tester.pump();
      expect(session.written, startsWith('tmux new -A -s main;echo __RC_'));
      expect(session.written, isNot(contains('echo other')));
      finishLastCommand(first);
      await tester.pump();
      await tester.pump();

      // The connection drops and comes back with a new shell.
      session.connected = false;
      first.end();
      states.add(const SSHConnectionState.reconnecting(reconnectAttempt: 1));
      await tester.pump();
      session.writes.clear();
      session.connected = true;
      states.add(const SSHConnectionState.connected());
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(session.shells, hasLength(2));
      expect(session.written, startsWith('tmux new -A -s main;echo __RC_'));
    });

    testWidgets('a snippet that needs values is not run on its own', (
      tester,
    ) async {
      await store.put(
        Snippet.create(
          name: 'Needs input',
          steps: const [SnippetStep(command: r'echo ${X}')],
        ).copyWith(runOnConnect: [server.id]),
      );
      await pumpTerminal(tester);
      await connect(tester);
      await tester.pump();

      expect(session.writes, isEmpty);
      expect(
        find.text('"Needs input" needs values. Run it from Snippets.'),
        findsOneWidget,
      );
    });

    testWidgets('one that asks first shows the commands and waits for a yes', (
      tester,
    ) async {
      await store.put(
        Snippet.create(
          name: 'Careful',
          steps: const [SnippetStep(command: 'rm -rf build')],
          askFirst: true,
        ).copyWith(runOnConnect: [server.id]),
      );
      await pumpTerminal(tester);
      await connect(tester);
      await tester.pumpAndSettle();

      expect(session.writes, isEmpty);
      expect(find.text('Run these commands'), findsOneWidget);
      expect(find.byKey(const ValueKey('preview-0')), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(session.writes, isEmpty);
    });
  });
}
