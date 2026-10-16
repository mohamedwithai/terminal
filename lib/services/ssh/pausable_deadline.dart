import 'dart:async';

/// A time limit that stops counting while [pause]d.
///
/// The SSH handshake limit pauses while the user decides on an unknown host
/// key, so reading the fingerprint never makes the connection time out. It
/// counts in timer ticks rather than with a stopwatch, so fake timers in
/// tests drive it.
class PausableDeadline {
  PausableDeadline(Duration limit)
    : _remaining = limit,
      _tick = limit < const Duration(seconds: 1)
          ? Duration(microseconds: (limit.inMicroseconds ~/ 10).clamp(1000, 100000))
          : const Duration(milliseconds: 100) {
    _timer = Timer.periodic(_tick, _onTick);
  }

  final Duration _tick;
  Duration _remaining;
  var _paused = false;
  Timer? _timer;
  final _expired = Completer<void>();

  /// Completes once the limit has run out.
  Future<void> get expired => _expired.future;

  bool get isPaused => _paused;

  void pause() => _paused = true;

  void resume() => _paused = false;

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void _onTick(Timer timer) {
    if (_paused) {
      return;
    }
    _remaining -= _tick;
    if (_remaining <= Duration.zero) {
      cancel();
      if (!_expired.isCompleted) {
        _expired.complete();
      }
    }
  }
}
