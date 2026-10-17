import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:ssh_app/services/ssh/ssh_socket_factory.dart';

/// [SSHSocketFactory] that records each connect and answers with
/// [onConnect], or refuses the connection when that is null.
class FakeSSHSocketFactory implements SSHSocketFactory {
  FakeSSHSocketFactory({this.onConnect});

  Future<SSHSocket> Function(String host, int port, Duration? timeout)?
  onConnect;

  /// `host:port` of every connect, in order.
  final List<String> calls = [];

  @override
  Future<SSHSocket> connect(String host, int port, {Duration? timeout}) {
    calls.add('$host:$port');
    if (onConnect != null) {
      return onConnect!(host, port, timeout);
    }
    throw const SocketException(
      'Connection refused',
      osError: OSError('Connection refused', 111),
    );
  }
}

/// TCP connection to a peer that accepts but never sends a byte.
class SilentSSHSocket implements SSHSocket {
  final _incoming = StreamController<Uint8List>();
  final _outgoing = StreamController<List<int>>();
  final _done = Completer<void>();
  bool wasClosed = false;

  SilentSSHSocket() {
    _outgoing.stream.listen((_) {});
  }

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    destroy();
  }

  @override
  void destroy() {
    wasClosed = true;
    if (!_done.isCompleted) {
      _done.complete();
    }
    _incoming.close();
  }

  @override
  Future<void> flush() async {}
}
