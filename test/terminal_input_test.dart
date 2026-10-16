import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/screens/terminal_input.dart';
import 'package:ssh_app/screens/terminal_keyboard_bar.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('controlCode', () {
    test('maps letters of either case to 0x01-0x1A', () {
      expect(controlCode('c'.codeUnitAt(0)), 0x03);
      expect(controlCode('C'.codeUnitAt(0)), 0x03);
      expect(controlCode('l'.codeUnitAt(0)), 0x0c);
      expect(controlCode('d'.codeUnitAt(0)), 0x04);
      expect(controlCode('z'.codeUnitAt(0)), 0x1a);
      expect(controlCode('A'.codeUnitAt(0)), 0x01);
    });

    test('maps the symbols a terminal maps', () {
      expect(controlCode('['.codeUnitAt(0)), 0x1b);
      expect(controlCode(' '.codeUnitAt(0)), 0x00);
      expect(controlCode('@'.codeUnitAt(0)), 0x00);
      expect(controlCode(r'\'.codeUnitAt(0)), 0x1c);
      expect(controlCode(']'.codeUnitAt(0)), 0x1d);
      expect(controlCode('^'.codeUnitAt(0)), 0x1e);
      expect(controlCode('_'.codeUnitAt(0)), 0x1f);
      expect(controlCode('/'.codeUnitAt(0)), 0x1f);
      expect(controlCode('?'.codeUnitAt(0)), 0x7f);
    });

    test('leaves characters without a control code alone', () {
      expect(controlCode('1'.codeUnitAt(0)), isNull);
      expect(controlCode('é'.codeUnitAt(0)), isNull);
      expect(controlCode('-'.codeUnitAt(0)), isNull);
    });
  });

  group('applyModifiers', () {
    test('CTRL sends the control code', () {
      expect(applyModifiers('c', ctrl: true), '\x03');
      expect(applyModifiers('L', ctrl: true), '\x0c');
      expect(applyModifiers('d', ctrl: true), '\x04');
      expect(applyModifiers('z', ctrl: true), '\x1a');
      expect(applyModifiers('[', ctrl: true), '\x1b');
      expect(applyModifiers(' ', ctrl: true), '\x00');
    });

    test('ALT puts ESC in front and keeps the case', () {
      expect(applyModifiers('x', alt: true), '\x1bx');
      expect(applyModifiers('X', alt: true), '\x1bX');
      expect(applyModifiers('.', alt: true), '\x1b.');
    });

    test('CTRL and ALT together send ESC and the control code', () {
      expect(applyModifiers('c', ctrl: true, alt: true), '\x1b\x03');
    });

    test('only the first character of a word is modified', () {
      expect(applyModifiers('ls', ctrl: true), '\x0cs');
      expect(applyModifiers('hello', alt: true), '\x1bhello');
      expect(applyModifiers('😀x', alt: true), '\x1b😀x');
    });

    test('unmodified or unmappable text is unchanged', () {
      expect(applyModifiers('c'), 'c');
      expect(applyModifiers('1', ctrl: true), '1');
      expect(applyModifiers('', ctrl: true), '');
    });
  });

  group('ModifierTerminal', () {
    late TerminalModifiers modifiers;
    late ModifierTerminal terminal;
    late StringBuffer output;

    setUp(() {
      modifiers = TerminalModifiers();
      terminal = ModifierTerminal(modifiers: modifiers);
      output = StringBuffer();
      terminal.onOutput = output.write;
    });

    test('a one-shot CTRL applies to the next text, then turns off', () {
      modifiers.toggleCtrl();
      terminal.textInput('c');
      terminal.textInput('c');

      expect(output.toString(), '\x03c');
      expect(modifiers.ctrl, ModifierLatch.off);
    });

    test('a locked modifier stays on', () {
      modifiers
        ..toggleAlt()
        ..toggleAlt();
      terminal.textInput('b');
      terminal.textInput('f');

      expect(output.toString(), '\x1bb\x1bf');
      expect(modifiers.alt, ModifierLatch.locked);
    });

    test('special keys take the modifier through xterm', () {
      modifiers.toggleCtrl();
      expect(terminal.keyInput(TerminalKey.arrowUp), isTrue);

      expect(output.toString(), '\x1b[1;5A');
      expect(modifiers.ctrl, ModifierLatch.off);
    });

    test('a letter key is left for the text that follows it', () {
      // TerminalView offers a soft keyboard letter to keyInput first and
      // sends it as text when that returns false.
      modifiers.toggleCtrl();
      expect(terminal.keyInput(TerminalKey.keyC), isFalse);
      expect(modifiers.ctrl, ModifierLatch.once);

      terminal.textInput('c');
      expect(output.toString(), '\x03');
    });

    test('keys held on a hardware keyboard still work', () {
      expect(terminal.keyInput(TerminalKey.keyC, ctrl: true), isTrue);
      expect(output.toString(), '\x03');
    });

    test('pasted text is never modified', () {
      modifiers.toggleCtrl();
      terminal.paste('cat file');

      expect(output.toString(), 'cat file');
      expect(modifiers.ctrl, ModifierLatch.once);
    });

    test('taking a modifier notifies listeners', () {
      var notified = 0;
      modifiers
        ..toggleCtrl()
        ..addListener(() => notified++);

      modifiers.take();
      modifiers.take();

      expect(notified, 1);
    });
  });
}
