import 'dart:async';

/// A terminal window size, in character cells and in pixels.
typedef PtySize = ({int columns, int rows, int pixelWidth, int pixelHeight});

/// Sends the terminal's size to the remote PTY once it has settled.
///
/// The view resizes on every frame while the soft keyboard slides in or out,
/// and each resize the remote sees sends SIGWINCH to the program in front.
/// This waits for [delay] without a change, then sends only the final size,
/// and skips a size the PTY already has.
class PtyResizeDebouncer {
  PtyResizeDebouncer({
    required this.send,
    this.delay = const Duration(milliseconds: 100),
  });

  final void Function(PtySize size) send;
  final Duration delay;

  Timer? _timer;

  /// The most recent size of the view.
  PtySize? _latest;

  /// Columns and rows the PTY has, as far as this knows.
  (int, int)? _sent;

  /// Records a new view size and sends it after [delay], unless another size
  /// arrives first.
  void resize(PtySize size) {
    _latest = size;
    _timer?.cancel();
    _timer = Timer(delay, flush);
  }

  /// Sends the latest size now, if the PTY does not have it yet.
  void flush() {
    _timer?.cancel();
    _timer = null;
    final size = _latest;
    if (size == null || (size.columns, size.rows) == _sent) {
      return;
    }
    _sent = (size.columns, size.rows);
    send(size);
  }

  /// Records that a PTY was opened (or resized) at [columns]x[rows], and sends
  /// the latest size straight away if the view changed while it was opening.
  void opened(int columns, int rows) {
    _sent = (columns, rows);
    flush();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
