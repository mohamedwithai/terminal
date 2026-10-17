import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/screens/terminal_keyboard_bar.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('escape and arrows produce the sequences xterm sends to a PTY', () {
    final terminal = Terminal();
    final output = StringBuffer();
    terminal.onOutput = output.write;

    terminal.keyInput(TerminalKey.escape);
    terminal.keyInput(TerminalKey.tab);
    terminal.keyInput(TerminalKey.arrowUp);
    terminal.keyInput(TerminalKey.arrowDown);
    terminal.keyInput(TerminalKey.arrowLeft);
    terminal.keyInput(TerminalKey.arrowRight);
    terminal.charInput('c'.codeUnitAt(0), ctrl: true);
    terminal.textInput('|~/');

    expect(output.toString(), '\x1b\t\x1b[A\x1b[B\x1b[D\x1b[C\x03|~/');
  });

  test('a second press locks a modifier and a sent key clears one-shot', () {
    expect(advanceModifierLatch(ModifierLatch.off), ModifierLatch.once);
    expect(advanceModifierLatch(ModifierLatch.once), ModifierLatch.locked);
    expect(advanceModifierLatch(ModifierLatch.locked), ModifierLatch.off);
    expect(releaseOneShotModifier(ModifierLatch.once), ModifierLatch.off);
    expect(releaseOneShotModifier(ModifierLatch.locked), ModifierLatch.locked);
    expect(releaseOneShotModifier(ModifierLatch.off), ModifierLatch.off);
  });

  testWidgets('keyboard bar forwards keys and toggles modifiers', (
    tester,
  ) async {
    TerminalKey? key;
    String? text;
    var ctrl = ModifierLatch.off;
    var pastes = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalKeyboardBar(
            ctrl: ctrl,
            alt: ModifierLatch.off,
            onToggleCtrl: () => ctrl = advanceModifierLatch(ctrl),
            onToggleAlt: () {},
            onKey: (value) => key = value,
            onText: (value) => text = value,
            onPaste: () => pastes++,
          ),
        ),
      ),
    );

    await tester.tap(find.text('ESC'));
    await tester.tap(find.text('|'));
    await tester.tap(find.text('CTRL'));
    await tester.drag(find.byType(PageView), const Offset(-400, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Paste'));

    expect(key, TerminalKey.escape);
    expect(text, '|');
    expect(ctrl, ModifierLatch.once);
    expect(pastes, 1);
  });

  testWidgets('locked modifier shows a lock icon', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TerminalKeyboardBar(
            ctrl: ModifierLatch.locked,
            alt: ModifierLatch.once,
            onToggleCtrl: _noop,
            onToggleAlt: _noop,
            onKey: _noopKey,
            onText: _noopText,
            onPaste: _noop,
          ),
        ),
      ),
    );

    expect(find.byTooltip('CTRL, locked'), findsOneWidget);
    expect(find.byIcon(Icons.lock), findsOneWidget);
    expect(find.byTooltip('ALT, next key'), findsOneWidget);
  });
}

void _noop() {}

void _noopKey(TerminalKey key) {}

void _noopText(String text) {}
