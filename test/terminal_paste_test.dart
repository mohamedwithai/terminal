import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/screens/terminal_paste.dart';

void main() {
  test('line breaks become CR, as Enter sends', () {
    expect(preparePaste('a\nb\r\nc\rd'), 'a\rb\rc\rd');
  });

  test('bracketed paste markers are removed from the text', () {
    expect(preparePaste('x\x1b[201~y\x1b[200~z'), 'xyz');
  });

  test('only text with a line break needs confirmation', () {
    expect(pasteNeedsConfirmation('ls -la'), isFalse);
    expect(pasteNeedsConfirmation('ls\n'), isTrue);
    expect(pasteNeedsConfirmation('ls\r'), isTrue);
  });

  test('the preview shows control characters and counts lines', () {
    final preview = pastePreview('echo hi\x1b[31m\r\nnext\tok\x07\n');

    expect(preview.text, 'echo hi␛[31m\nnext\tok␇');
    expect(preview.lineCount, 2);
    expect(preview.hiddenLines, 0);
  });

  test('a long paste is cut short in the preview', () {
    final text = List.generate(25, (i) => 'line $i').join('\n');
    final preview = pastePreview(text, maxLines: 20);

    expect(preview.text.split('\n'), hasLength(20));
    expect(preview.text.split('\n').last, 'line 19');
    expect(preview.lineCount, 25);
    expect(preview.hiddenLines, 5);
  });
}
