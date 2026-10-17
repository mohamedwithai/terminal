import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/providers/ssh_providers.dart';
import 'package:ssh_app/screens/terminal_screen.dart';
import 'package:ssh_app/services/ssh/ssh_connection_service.dart';
import 'package:ssh_app/services/ssh/ssh_connection_session.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';
import 'package:xterm/xterm.dart';

import 'support/fake_terminal_session.dart';

void main() {
  final server = ServerConfig.create(
    id: 'term-1',
    label: 'Build box',
    host: 'example.com',
    username: 'ada',
    authType: AuthType.password,
    now: DateTime.utc(2026, 5, 1),
  );

  testWidgets('CTRL is one-shot until a second tap locks it', (tester) async {
    await tester.pumpWidget(_terminalApp(server));
    await tester.pump();

    await tester.tap(find.text('CTRL'));
    await tester.pump();
    expect(find.byTooltip('CTRL, next key'), findsOneWidget);
    expect(find.byIcon(Icons.lock), findsNothing);

    await tester.tap(find.text('ESC'));
    await tester.pump();
    expect(find.byTooltip('CTRL'), findsOneWidget);

    await tester.tap(find.text('CTRL'));
    await tester.pump();
    await tester.tap(find.text('CTRL'));
    await tester.pump();
    expect(find.byTooltip('CTRL, locked'), findsOneWidget);
    expect(find.byIcon(Icons.lock), findsOneWidget);

    await tester.tap(find.text('ESC'));
    await tester.pump();
    expect(find.byTooltip('CTRL, locked'), findsOneWidget);

    await tester.tap(find.text('CTRL'));
    await tester.pump();
    expect(find.byTooltip('CTRL'), findsOneWidget);
    expect(find.byIcon(Icons.lock), findsNothing);
  });

  testWidgets('back asks before disconnecting', (tester) async {
    final disconnects = <int>[0];
    await tester.pumpWidget(
      _terminalApp(
        server,
        disconnects: disconnects,
        pushed: true,
        session: RecordingSession(server)..connected = true,
        states: Stream.value(const SSHConnectionState.connected()),
      ),
    );
    await tester.tap(find.text('Open terminal'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(find.text('Disconnect?'), findsOneWidget);
    expect(disconnects.single, 0);

    await tester.tap(find.text('Stay'));
    await tester.pumpAndSettle();
    expect(find.text('Disconnect?'), findsNothing);
    expect(find.byType(TerminalScreen), findsOneWidget);
    expect(disconnects.single, 0);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Disconnect'));
    await tester.pumpAndSettle();

    expect(disconnects.single, 1);
    expect(find.text('Open terminal'), findsOneWidget);
    expect(find.byType(TerminalScreen), findsNothing);
  });

  testWidgets('Disconnect in the menu asks before disconnecting', (tester) async {
    final disconnects = <int>[0];
    await tester.pumpWidget(
      _terminalApp(
        server,
        disconnects: disconnects,
        pushed: true,
        session: RecordingSession(server)..connected = true,
        states: Stream.value(const SSHConnectionState.connected()),
      ),
    );
    await tester.tap(find.text('Open terminal'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Disconnect'));
    await tester.pumpAndSettle();
    expect(find.text('Disconnect?'), findsOneWidget);

    await tester.tap(find.text('Stay'));
    await tester.pumpAndSettle();
    expect(disconnects.single, 0);
    expect(find.byType(TerminalScreen), findsOneWidget);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Disconnect'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Disconnect'));
    await tester.pumpAndSettle();
    expect(disconnects.single, 1);
    expect(find.byType(TerminalScreen), findsNothing);
  });

  group('paste', () {
    testWidgets('one line from the keyboard bar is pasted at once', (
      tester,
    ) async {
      _FakeClipboard(tester).text = 'ls -la';
      final session = RecordingSession(server);
      await tester.pumpWidget(_terminalApp(server, session: session));
      await tester.pump();
      session.writes.clear();

      await _tapPasteKey(tester);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(session.written, 'ls -la');
    });

    testWidgets('several lines are shown and pasted only when confirmed', (
      tester,
    ) async {
      final clipboard = _FakeClipboard(tester)
        ..text = 'echo one\r\nrm -rf build\x1b[2J\n';
      final session = RecordingSession(server);
      await tester.pumpWidget(_terminalApp(server, session: session));
      await tester.pump();
      session.writes.clear();

      await _tapPasteKey(tester);
      await tester.pumpAndSettle();
      expect(find.text('Paste 2 lines?'), findsOneWidget);
      expect(find.textContaining('may run these lines'), findsOneWidget);
      // The escape sequence is shown, not hidden.
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('paste-preview'))).data,
        'echo one\nrm -rf build␛[2J',
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(session.writes, isEmpty);

      clipboard.text = 'echo one\necho two';
      await _tapPasteKey(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Paste'));
      await tester.pumpAndSettle();
      expect(session.written, 'echo one\recho two');
    });

    testWidgets('bracketed paste is used when the program turns it on', (
      tester,
    ) async {
      final clipboard = _FakeClipboard(tester)..text = 'vim\x1b[201~:q!';
      final session = RecordingSession(server);
      await tester.pumpWidget(_terminalApp(server, session: session));
      await tester.pump();
      _terminal(tester).write('\x1b[?2004h');
      session.writes.clear();

      await _tapPasteKey(tester);
      await tester.pumpAndSettle();
      // The end marker inside the text cannot close the bracket early.
      expect(session.written, '\x1b[200~vim:q!\x1b[201~');

      clipboard.text = 'line one\nline two';
      session.writes.clear();
      await _tapPasteKey(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('bracketed paste'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Paste'));
      await tester.pumpAndSettle();
      expect(session.written, '\x1b[200~line one\rline two\x1b[201~');

      // Once the program turns it off, paste is plain again.
      _terminal(tester).write('\x1b[?2004l');
      clipboard.text = 'pwd';
      session.writes.clear();
      await _tapPasteKey(tester);
      await tester.pumpAndSettle();
      expect(session.written, 'pwd');
    });

    testWidgets('a pasted command keeps an armed CTRL for the next key', (
      tester,
    ) async {
      _FakeClipboard(tester).text = 'cat';
      final session = RecordingSession(server);
      await tester.pumpWidget(_terminalApp(server, session: session));
      await tester.pump();
      await tester.tap(find.text('CTRL'));
      await tester.pump();
      session.writes.clear();

      await _tapPasteKey(tester);
      await tester.pumpAndSettle();

      expect(session.written, 'cat');
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('modifier-hint'))).data,
        'CTRL armed',
      );
    });
  });

  group('modifiers and the soft keyboard', () {
    testWidgets('CTRL applies to a letter typed on the soft keyboard', (
      tester,
    ) async {
      final session = RecordingSession(server);
      await tester.pumpWidget(_terminalApp(server, session: session));
      await _openSoftKeyboard(tester);

      await tester.tap(find.text('CTRL'));
      await tester.pump();
      session.writes.clear();

      await _imeCommit(tester, 'c');
      expect(session.writes, [
        [0x03],
      ]);
      expect(find.byTooltip('CTRL'), findsOneWidget);

      await _imeCommit(tester, 'c');
      expect(session.writes.last, [0x63]);
    });

    testWidgets('CTRL+L, CTRL+D and CTRL+Z from the soft keyboard', (
      tester,
    ) async {
      final session = RecordingSession(server);
      await tester.pumpWidget(_terminalApp(server, session: session));
      await _openSoftKeyboard(tester);

      for (final letter in ['l', 'D', 'z']) {
        await tester.tap(find.text('CTRL'));
        await tester.pump();
        await _imeCommit(tester, letter);
      }

      expect(session.writes.sublist(session.writes.length - 3), [
        [0x0c],
        [0x04],
        [0x1a],
      ]);
    });

    testWidgets('a composed word gets the modifier on its first letter only', (
      tester,
    ) async {
      final session = RecordingSession(server);
      await tester.pumpWidget(_terminalApp(server, session: session));
      await _openSoftKeyboard(tester);
      await tester.tap(find.text('CTRL'));
      await tester.pump();
      session.writes.clear();

      // Gboard composes the word, then commits it in one go.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  ls',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 2, end: 4),
        ),
      );
      await tester.pump();
      expect(session.writes, isEmpty);

      await _imeCommit(tester, 'ls');
      expect(session.writes.single, [0x0c, 0x73]);
      expect(find.byTooltip('CTRL'), findsOneWidget);
    });

    testWidgets('ALT puts ESC before soft keyboard text and a lock stays on', (
      tester,
    ) async {
      final session = RecordingSession(server);
      await tester.pumpWidget(_terminalApp(server, session: session));
      await _openSoftKeyboard(tester);
      await tester.tap(find.text('ALT'));
      await tester.pump();
      await tester.tap(find.text('ALT'));
      await tester.pump();
      session.writes.clear();

      await _imeCommit(tester, 'b');
      await _imeCommit(tester, 'F');

      expect(session.written, '\x1bb\x1bF');
      expect(find.byTooltip('ALT, locked'), findsOneWidget);
    });

    testWidgets('CTRL applies to toolbar keys', (tester) async {
      final session = RecordingSession(server);
      await tester.pumpWidget(_terminalApp(server, session: session));
      await tester.pump();
      await tester.tap(find.text('CTRL'));
      await tester.pump();
      session.writes.clear();

      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump();

      expect(session.written, '\x1b[1;5A');
    });
  });

  group('PTY size', () {
    testWidgets('keyboard show and hide each resize the PTY once settled', (
      tester,
    ) async {
      _phone(tester);
      final session = RecordingSession(server);
      await tester.pumpWidget(_terminalApp(server, session: session));
      // The connection banner arrives on the second frame.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(session.resizes, isNotEmpty);
      final full = session.resizes.last;
      // The whole window, not one cell.
      expect(full.pixelWidth, greaterThan(full.columns));
      expect(full.pixelHeight, greaterThan(full.rows));
      session.resizes.clear();

      // The keyboard slides in over several frames.
      for (final inset in [300.0, 600.0, 900.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(session.resizes, isEmpty);
      await tester.pump(const Duration(milliseconds: 150));
      expect(session.resizes, hasLength(1));
      final shrunk = session.resizes.single;
      expect(shrunk.columns, full.columns);
      expect(shrunk.rows, lessThan(full.rows));

      // Hiding the keyboard grows the PTY back.
      tester.view.resetViewInsets();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(session.resizes, hasLength(2));
      expect(session.resizes.last.columns, full.columns);
      expect(session.resizes.last.rows, full.rows);
    });

    testWidgets('rotation and pinch-zoom resize the PTY', (tester) async {
      _phone(tester);
      final session = RecordingSession(server);
      await tester.pumpWidget(_terminalApp(server, session: session));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      final portrait = session.resizes.last;

      tester.view.physicalSize = const Size(2340, 1080);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      final landscape = session.resizes.last;
      expect(landscape.columns, greaterThan(portrait.columns));
      expect(landscape.rows, lessThan(portrait.rows));

      // Pinch out: a bigger font fits fewer columns.
      final center = tester.getCenter(find.byType(TerminalView));
      final first = await tester.startGesture(center - const Offset(40, 0));
      final second = await tester.startGesture(center + const Offset(40, 0));
      for (var i = 1; i <= 5; i++) {
        await first.moveTo(center - Offset(40.0 + 20 * i, 0));
        await second.moveTo(center + Offset(40.0 + 20 * i, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await first.up();
      await second.up();
      await tester.pump(const Duration(milliseconds: 150));
      expect(session.resizes.last.columns, lessThan(landscape.columns));
    });

    testWidgets('the system navigation bar does not cost terminal rows', (
      tester,
    ) async {
      _phone(tester);
      tester.view.padding = const FakeViewPadding(bottom: 144);
      final session = RecordingSession(server);
      await tester.pumpWidget(_terminalApp(server, session: session));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      final height = tester.getSize(find.byType(TerminalView)).height;
      final cellHeight = _render(tester).cellSize.height as double;
      expect(session.resizes.last.rows, (height / cellHeight).floor());
    });

    testWidgets('a shell opens at the current size', (tester) async {
      _phone(tester);
      final session = RecordingSession(server)..connected = true;
      final states = StreamController<SSHConnectionState>.broadcast();
      addTearDown(states.close);
      await tester.pumpWidget(
        _terminalApp(server, session: session, states: states.stream),
      );
      await tester.pump(const Duration(milliseconds: 150));
      final size = session.resizes.last;

      states.add(const SSHConnectionState.connected());
      await tester.pump();
      await tester.pump();

      expect(session.openedShells.single, (
        columns: size.columns,
        rows: size.rows,
      ));
    });
  });

  group('reconnect', () {
    testWidgets('a reconnect announces itself and uses the new shell', (
      tester,
    ) async {
      final session = RecordingSession(server)..connected = true;
      final states = StreamController<SSHConnectionState>.broadcast();
      addTearDown(states.close);
      await tester.pumpWidget(
        _terminalApp(server, session: session, states: states.stream),
      );
      states.add(const SSHConnectionState.connected());
      await tester.pump();
      await tester.pump();
      expect(session.shells, hasLength(1));
      session.shells.first.emit('old-prompt\$ ');
      await tester.pump();

      // The connection drops and takes the shell with it.
      session.connected = false;
      session.shells.first.end();
      states.add(const SSHConnectionState.reconnecting(reconnectAttempt: 1));
      await tester.pump();
      expect(
        find.textContaining('Reconnecting (attempt 1 of 3)'),
        findsOneWidget,
      );

      session.connected = true;
      states.add(const SSHConnectionState.connected());
      await tester.pump();
      await tester.pump();
      expect(session.shells, hasLength(2));
      session.shells.last.emit('new-prompt\$ ');
      await tester.pump();

      final text = _screenText(tester);
      expect(text, contains(reconnectedBanner));
      expect(text.indexOf('old-prompt'), lessThan(text.indexOf('---')));
      expect(
        text.indexOf(reconnectedBanner),
        lessThan(text.indexOf('new-prompt')),
      );
      expect(text, isNot(contains('[session closed]')));
    });

    testWidgets('waiting for the network is shown in the banner', (
      tester,
    ) async {
      final states = StreamController<SSHConnectionState>.broadcast();
      addTearDown(states.close);
      await tester.pumpWidget(_terminalApp(server, states: states.stream));
      states.add(
        const SSHConnectionState.reconnecting(
          reconnectAttempt: 0,
          waitingFor: 'a network connection',
        ),
      );
      await tester.pump();

      expect(
        find.text('Waiting for a network connection to reconnect.'),
        findsOneWidget,
      );
    });

    testWidgets('a shell that exits is not replaced', (tester) async {
      final session = RecordingSession(server)
        ..connected = true
        ..fakeClient = FakeClient();
      final states = StreamController<SSHConnectionState>.broadcast();
      addTearDown(states.close);
      await tester.pumpWidget(
        _terminalApp(server, session: session, states: states.stream),
      );
      states.add(const SSHConnectionState.connected());
      await tester.pump();
      await tester.pump();

      session.shells.single.end();
      await tester.pump();
      expect(_screenText(tester), contains('[session closed]'));

      await tester.tap(find.text('CTRL'));
      await tester.pump();
      await tester.pump();
      expect(session.shells, hasLength(1));
    });
  });

  group('selection', () {
    testWidgets('long press selects a word and Copy copies plain text', (
      tester,
    ) async {
      final clipboard = _FakeClipboard(tester);
      await tester.pumpWidget(_terminalApp(server));
      await tester.pump();
      _terminal(tester).write('hello \x1b[31mworld\x1b[0m   \r\nsecond\r\n');
      await tester.pump();

      await tester.longPressAt(_cellCenter(tester, 8, 0));
      await tester.pump();

      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Select all'), findsOneWidget);
      expect(find.text('Paste'), findsOneWidget);
      expect(_handle('start'), findsOneWidget);
      expect(_handle('end'), findsOneWidget);

      await tester.tap(find.text('Copy'));
      await tester.pump();

      expect(clipboard.text, 'world');
      expect(find.text('Copied'), findsOneWidget);
      expect(find.text('Copy'), findsNothing);
    });

    testWidgets('dragging a handle extends the selection across lines', (
      tester,
    ) async {
      final clipboard = _FakeClipboard(tester);
      await tester.pumpWidget(_terminalApp(server));
      await tester.pump();
      _terminal(tester).write('hello world   \r\nsecond line\r\n');
      await tester.pump();

      await tester.longPressAt(_cellCenter(tester, 1, 0));
      await tester.pump();
      final cell = _render(tester).cellSize;
      // From the end of "hello" (column 5) to after "second" (column 6).
      await tester.drag(
        _handle('end'),
        Offset(cell.width, cell.height),
        touchSlopY: 0,
      );
      await tester.pump();

      await tester.tap(find.text('Copy'));
      await tester.pump();
      expect(clipboard.text, 'hello world\nsecond');
    });

    testWidgets('a selection works in the scrollback', (tester) async {
      final clipboard = _FakeClipboard(tester);
      await tester.pumpWidget(_terminalApp(server));
      await tester.pump();
      final terminal = _terminal(tester);
      terminal.write('scrollback\r\n');
      for (var i = 0; i < 200; i++) {
        terminal.write('line $i\r\n');
      }
      await tester.pump();
      expect(find.text('Copy'), findsNothing);

      // Scroll back to the top, then select there.
      await tester.fling(
        find.byType(TerminalView),
        const Offset(0, 20000),
        20000,
      );
      await tester.pumpAndSettle();
      await tester.longPressAt(_cellCenter(tester, 3, 0));
      await tester.pump();
      await tester.tap(find.text('Copy'));
      await tester.pump();

      expect(clipboard.text, 'scrollback');
    });

    testWidgets('Select all then Copy copies the whole buffer', (
      tester,
    ) async {
      final clipboard = _FakeClipboard(tester);
      await tester.pumpWidget(_terminalApp(server));
      await tester.pump();
      _terminal(tester).write('one  two\r\nthree\r\n');
      await tester.pump();

      await tester.longPressAt(_cellCenter(tester, 0, 1));
      await tester.pump();
      await tester.tap(find.text('Select all'));
      await tester.pump();
      await tester.tap(find.text('Copy'));
      await tester.pump();

      expect(clipboard.text, 'one  two\nthree');
    });

    testWidgets('a tap clears the selection', (tester) async {
      await tester.pumpWidget(_terminalApp(server));
      await tester.pump();
      _terminal(tester).write('hello world\r\n');
      await tester.pump();

      await tester.longPressAt(_cellCenter(tester, 1, 0));
      await tester.pump();
      expect(find.text('Copy'), findsOneWidget);

      await tester.tapAt(_cellCenter(tester, 3, 5));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Copy'), findsNothing);
      expect(_handle('start'), findsNothing);
    });

    testWidgets('long press on empty space offers Paste', (tester) async {
      final clipboard = _FakeClipboard(tester)..text = 'echo hi\nls';
      final session = RecordingSession(server);
      await tester.pumpWidget(_terminalApp(server, session: session));
      await tester.pump();

      await tester.longPressAt(_cellCenter(tester, 10, 5));
      await tester.pump();
      expect(find.text('Copy'), findsNothing);
      expect(find.text('Paste'), findsOneWidget);
      session.writes.clear();

      await tester.tap(find.text('Paste'));
      await tester.pumpAndSettle();
      expect(find.text('Paste 2 lines?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Paste'));
      await tester.pumpAndSettle();

      expect(session.written, 'echo hi\rls');
      expect(clipboard.text, 'echo hi\nls');
      expect(find.text('Paste'), findsNothing);
    });
  });
}

/// Paste is on the second page of the key bar.
Future<void> _tapPasteKey(WidgetTester tester) async {
  final bar = find.byType(PageView);
  await tester.drag(bar, const Offset(-400, 0));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Paste'));
}

Future<void> _openSoftKeyboard(WidgetTester tester) async {
  await tester.pump();
  await tester.tap(find.byType(TerminalView));
  // Past xterm's double-tap window.
  await tester.pump(const Duration(milliseconds: 400));
  expect(tester.testTextInput.hasAnyClients, isTrue);
}

/// Commits [text] the way an IME does. TerminalView keeps two spaces in the
/// field so it can see deletions.
Future<void> _imeCommit(WidgetTester tester, String text) async {
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: '  $text',
      selection: TextSelection.collapsed(offset: 2 + text.length),
    ),
  );
  await tester.pump();
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

Terminal _terminal(WidgetTester tester) {
  return tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
}

String _screenText(WidgetTester tester) => _terminal(tester).buffer.getText();

dynamic _render(WidgetTester tester) {
  return tester.state<TerminalViewState>(find.byType(TerminalView))
      .renderTerminal;
}

Offset _cellCenter(WidgetTester tester, int column, int row) {
  final render = tester
      .state<TerminalViewState>(find.byType(TerminalView))
      .renderTerminal;
  final cell = render.cellSize;
  return render.localToGlobal(
    render.getOffset(CellOffset(column, row)) +
        Offset(cell.width / 2, cell.height / 2),
  );
}

Finder _handle(String end) {
  return find.byKey(ValueKey('terminal-selection-$end-handle'));
}

class _FakeClipboard {
  _FakeClipboard(WidgetTester tester) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, _handle);
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
  }

  String? text;

  Future<Object?> _handle(MethodCall call) async {
    switch (call.method) {
      case 'Clipboard.setData':
        text = (call.arguments as Map)['text'] as String?;
      case 'Clipboard.getData':
        return text == null ? null : {'text': text};
    }
    return null;
  }
}

Widget _terminalApp(
  ServerConfig server, {
  List<int>? disconnects,
  bool pushed = false,
  SSHConnectionSession? session,
  Stream<SSHConnectionState>? states,
}) {
  final terminal = TerminalScreen(
    server: server,
    sessionId: 'session-1',
    autoConnect: false,
  );
  return ProviderScope(
    overrides: [
      sshConnectionServiceProvider.overrideWithValue(
        session == null
            ? SSHConnectionService(hostKeyVerifier: noKnownHosts())
            : SingleSessionService(session),
      ),
      sshSessionStateProvider.overrideWith(
        (ref, args) =>
            states ?? Stream.value(const SSHConnectionState.disconnected()),
      ),
      sshSessionControllerProvider.overrideWith((ref, args) {
        return _CountingController(
          ref: ref,
          sessionId: args.sessionId,
          server: args.server,
          disconnects: disconnects,
        );
      }),
    ],
    child: MaterialApp(
      home: pushed
          ? Builder(
              builder: (context) {
                return Scaffold(
                  body: TextButton(
                    onPressed: () {
                      Navigator.of(
                        context,
                      ).push(MaterialPageRoute<void>(builder: (_) => terminal));
                    },
                    child: const Text('Open terminal'),
                  ),
                );
              },
            )
          : terminal,
    ),
  );
}

class _CountingController extends SSHSessionController {
  _CountingController({
    required super.ref,
    required super.sessionId,
    required super.server,
    this.disconnects,
  });

  final List<int>? disconnects;

  @override
  Future<void> disconnect() async {
    if (disconnects != null) {
      disconnects![0] += 1;
    }
  }
}
