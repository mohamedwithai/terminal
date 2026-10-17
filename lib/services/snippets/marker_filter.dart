/// Removes the hidden exit-code marker of a snippet step from shell output.
///
/// A step that waits for the prompt is sent as `command;echo __RC_<nonce>=$?`.
/// The shell echoes that text, and prints `__RC_<nonce>=<code>` when the
/// command ends. This filter reports the code and hides both, so the marker is
/// never on screen. Text that might be the start of a marker is held back
/// until the next chunk shows what it is, since output arrives in arbitrary
/// pieces.
class MarkerFilter {
  MarkerFilter(this.nonce, {required this.onExitCode})
    : _echo = ';echo __RC_$nonce=\$?',
      _tag = '__RC_$nonce=',
      _result = RegExp('__RC_$nonce=(\\d+)(?=\\D)');

  final String nonce;

  /// Called with the exit code each time a result marker is seen.
  final void Function(int exitCode) onExitCode;

  final String _echo;
  final String _tag;
  final RegExp _result;
  var _held = '';
  var _swallowNewline = false;

  /// The text to append to a command so its exit code comes back.
  String get suffix => _echo;

  /// Filters one chunk of output and returns what is safe to show.
  String feed(String chunk) {
    var text = _held + chunk;
    _held = '';

    if (_swallowNewline) {
      if (text.startsWith('\r\n')) {
        text = text.substring(2);
        _swallowNewline = false;
      } else if (text.startsWith('\n')) {
        text = text.substring(1);
        _swallowNewline = false;
      } else if (text == '\r') {
        _held = text;
        return '';
      } else {
        _swallowNewline = false;
      }
    }

    text = text.replaceAll(_echo, '');

    final out = StringBuffer();
    var position = 0;
    for (final match in _result.allMatches(text)) {
      out.write(text.substring(position, match.start));
      onExitCode(int.parse(match.group(1)!));
      position = match.end;
      if (position < text.length && text[position] == '\r') position++;
      if (position < text.length && text[position] == '\n') {
        position++;
      } else if (position >= text.length) {
        _swallowNewline = true;
      }
    }
    final rest = text.substring(position);
    final hold = _partialSuffixLength(rest);
    _held = rest.substring(rest.length - hold);
    out.write(rest.substring(0, rest.length - hold));
    return out.toString();
  }

  /// Anything still held back, for when no more output will come.
  String flush() {
    final held = _held;
    _held = '';
    return held;
  }

  /// Length of the longest end of [text] that could be the beginning of a
  /// marker still being received.
  int _partialSuffixLength(String text) {
    final longest = _echo.length + 12;
    final max = text.length < longest ? text.length : longest;
    for (var length = max; length >= 1; length--) {
      final suffix = text.substring(text.length - length);
      if (_echo.startsWith(suffix) || _tag.startsWith(suffix)) {
        return length;
      }
      if (suffix.startsWith(_tag) &&
          RegExp(r'^\d*$').hasMatch(suffix.substring(_tag.length))) {
        return length;
      }
    }
    return 0;
  }
}
