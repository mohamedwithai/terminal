final _escapes = RegExp(
  r'\x1B\[[0-9;?]*[ -/]*[@-~]' // CSI, such as colors and cursor moves
  r'|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)' // OSC, such as window titles
  r'|\x1B[@-Z\\-_]', // other two-character escapes
);

/// Terminal output as plain text: escape codes removed, `\r\n` as `\n`, and
/// a bare `\r` (a redrawn line) dropped along with the text it overwrote.
String toPlainText(String output) {
  final text = output.replaceAll(_escapes, '').replaceAll('\r\n', '\n');
  final lines = text.split('\n');
  return lines
      .map((line) {
        final redraw = line.lastIndexOf('\r');
        return redraw < 0 ? line : line.substring(redraw + 1);
      })
      .join('\n')
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '');
}
