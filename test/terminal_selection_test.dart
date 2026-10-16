import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/screens/pty_resize.dart';
import 'package:ssh_app/screens/terminal_selection.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('terminalSelectionText', () {
    Terminal terminalWith(String output, {int columns = 20}) {
      return Terminal()
        ..resize(columns, 5)
        ..write(output);
    }

    String all(Terminal terminal) {
      return terminalSelectionText(
        terminal.buffer,
        BufferRangeLine(
          const CellOffset(0, 0),
          CellOffset(terminal.viewWidth, terminal.buffer.lines.length - 1),
        ),
      );
    }

    test('drops colors and trailing spaces, keeps gaps inside a line', () {
      // Cursor moves leave empty cells between the columns, like htop.
      final terminal = terminalWith(
        '\x1b[1;31mCPU\x1b[0m   \x1b[1;10H42%  \r\n\x1b[32mok\x1b[0m\r\n',
      );

      expect(all(terminal), 'CPU      42%\nok');
    });

    test('joins lines the terminal wrapped', () {
      final terminal = terminalWith('abcdefghij-klm\r\nnext', columns: 10);

      expect(all(terminal), 'abcdefghij-klm\nnext');
    });

    test('copies a wide character once', () {
      final terminal = terminalWith('a界b');

      expect(all(terminal), 'a界b');
    });

    test('copies part of a line', () {
      final terminal = terminalWith('hello world');
      final range = BufferRangeLine(
        const CellOffset(6, 0),
        const CellOffset(11, 0),
      );

      expect(terminalSelectionText(terminal.buffer, range), 'world');
    });

    test('a reversed range copies the same text', () {
      final terminal = terminalWith('one\r\ntwo');
      final range = BufferRangeLine(
        const CellOffset(3, 1),
        const CellOffset(0, 0),
      );

      expect(terminalSelectionText(terminal.buffer, range), 'one\ntwo');
    });
  });

  group('PtyResizeDebouncer', () {
    PtySize size(int columns, int rows) {
      return (
        columns: columns,
        rows: rows,
        pixelWidth: columns * 10,
        pixelHeight: rows * 20,
      );
    }

    testWidgets('sends only the last size of a burst', (tester) async {
      final sent = <PtySize>[];
      final debouncer = PtyResizeDebouncer(send: sent.add);
      addTearDown(debouncer.dispose);

      debouncer.resize(size(80, 40));
      await tester.pump(const Duration(milliseconds: 50));
      debouncer.resize(size(80, 30));
      await tester.pump(const Duration(milliseconds: 50));
      debouncer.resize(size(80, 20));
      await tester.pump(const Duration(milliseconds: 99));
      expect(sent, isEmpty);

      await tester.pump(const Duration(milliseconds: 1));
      expect(sent, [size(80, 20)]);
    });

    testWidgets('skips a size the PTY already has', (tester) async {
      final sent = <PtySize>[];
      final debouncer = PtyResizeDebouncer(send: sent.add);
      addTearDown(debouncer.dispose);

      debouncer.resize(size(80, 20));
      await tester.pump(const Duration(milliseconds: 100));
      debouncer.resize(size(80, 30));
      debouncer.resize(size(80, 20));
      await tester.pump(const Duration(milliseconds: 100));

      expect(sent, [size(80, 20)]);
    });

    testWidgets('a shell opened at an old size gets the new one at once', (
      tester,
    ) async {
      final sent = <PtySize>[];
      final debouncer = PtyResizeDebouncer(send: sent.add);
      addTearDown(debouncer.dispose);

      debouncer.resize(size(80, 20));
      debouncer.opened(80, 24);
      expect(sent, [size(80, 20)]);

      debouncer.opened(80, 20);
      await tester.pump(const Duration(milliseconds: 100));
      expect(sent, [size(80, 20)]);
    });
  });
}
