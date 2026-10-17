/// Follows what the user has typed since the last Enter or Ctrl+C, for when
/// the shell does not report its prompt. It sees only the keys sent, so
/// anything it cannot follow (arrow keys, history, Tab completion) makes it
/// give up on the line until the next Enter.
class InputLineTracker {
  final _line = StringBuffer();
  var _uncertain = false;

  /// What was typed on this line, or null when it cannot be known.
  String? get line => _uncertain ? null : _line.toString();

  /// Takes one piece of input as it is sent to the shell. Returns the
  /// lines that were submitted by it, null for one that could not be known.
  List<String?> feed(String data) {
    final submitted = <String?>[];
    final units = data.runes.toList();
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      switch (unit) {
        case 0x0d || 0x0a:
          submitted.add(line);
          _reset();
        case 0x03 || 0x15:
          // Ctrl+C and Ctrl+U throw the line away.
          _reset();
        case 0x17:
          _deleteWord();
        case 0x7f || 0x08:
          final text = _line.toString();
          if (text.isNotEmpty) {
            _line
              ..clear()
              ..write(
                String.fromCharCodes(text.runes.take(text.runes.length - 1)),
              );
          }
        case 0x09:
          // Tab completion changes the line in ways we cannot see.
          _uncertain = true;
        case 0x1b:
          // An escape sequence: arrows, Home, history. Skip it whole.
          _uncertain = true;
          if (i + 1 < units.length &&
              (units[i + 1] == 0x5b || units[i + 1] == 0x4f)) {
            i++;
            while (i + 1 < units.length && !_isFinal(units[i + 1])) {
              i++;
            }
            if (i + 1 < units.length) i++;
          } else if (i + 1 < units.length) {
            i++;
          }
        default:
          if (unit >= 0x20) _line.writeCharCode(unit);
      }
    }
    return submitted;
  }

  static bool _isFinal(int unit) => unit >= 0x40 && unit <= 0x7e;

  void _deleteWord() {
    final text = _line.toString().trimRight();
    final cut = text.lastIndexOf(' ');
    _line
      ..clear()
      ..write(cut < 0 ? '' : text.substring(0, cut + 1));
  }

  void _reset() {
    _line.clear();
    _uncertain = false;
  }

  /// Start over, for example when a new shell opens.
  void reset() => _reset();
}
