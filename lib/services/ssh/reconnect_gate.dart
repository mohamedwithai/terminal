import 'dart:async';

/// Whether it is worth trying to reconnect a lost session right now.
///
/// Android may cut the network of an app in the background or freeze it, and
/// without a network every attempt fails at once. The reconnect loop waits
/// until the app is in the foreground and online instead of spending its
/// attempts.
class ReconnectGate {
  ReconnectGate({this._foreground = true, this._online = true});

  bool _foreground;
  bool _online;
  final _changes = StreamController<void>.broadcast();

  /// Whether the app is in the foreground.
  bool get foreground => _foreground;
  set foreground(bool value) {
    if (value == _foreground) return;
    _foreground = value;
    _notify();
  }

  /// Whether the device has a network connection.
  bool get online => _online;
  set online(bool value) {
    if (value == _online) return;
    _online = value;
    _notify();
  }

  bool get isOpen => _foreground && _online;

  /// What a reconnect is waiting for, for the log and the UI. Null while the
  /// gate is open.
  String? get waitingFor => switch ((_foreground, _online)) {
    (true, true) => null,
    (false, true) => 'the app to return to the foreground',
    (true, false) => 'a network connection',
    (false, false) =>
      'the app to return to the foreground and a network connection',
  };

  /// Emits after every change.
  Stream<void> get changes => _changes.stream;

  void _notify() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  void dispose() {
    _changes.close();
  }
}
