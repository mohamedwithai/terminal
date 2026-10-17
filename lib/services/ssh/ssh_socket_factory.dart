import 'dart:async';

import 'package:dartssh2/dartssh2.dart';

/// Abstraction for creating [SSHSocket] connections.
abstract interface class SSHSocketFactory {
  Future<SSHSocket> connect(String host, int port, {Duration? timeout});
}

/// Default production socket factory using dartssh2 and dart:io sockets.
class DefaultSSHSocketFactory implements SSHSocketFactory {
  const DefaultSSHSocketFactory();

  @override
  Future<SSHSocket> connect(String host, int port, {Duration? timeout}) {
    return SSHSocket.connect(host, port, timeout: timeout);
  }
}
