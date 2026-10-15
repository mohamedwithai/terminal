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

  testWidgets('keyboard bar forwards keys and toggles modifiers', (tester) async {
    TerminalKey? key;
    String? text;
    var ctrl = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalKeyboardBar(
            ctrl: ctrl,
            alt: false,
            onToggleCtrl: () => ctrl = true,
            onToggleAlt: () {},
            onKey: (value) => key = value,
            onText: (value) => text = value,
          ),
        ),
      ),
    );

    await tester.tap(find.text('ESC'));
    await tester.tap(find.text('|'));
    await tester.tap(find.text('CTRL'));

    expect(key, TerminalKey.escape);
    expect(text, '|');
    expect(ctrl, isTrue);
  });
}