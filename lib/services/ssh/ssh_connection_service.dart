import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/services/ssh/host_key_verifier.dart';
import 'package:ssh_app/services/ssh/ssh_connection_session.dart';
import 'package:ssh_app/services/ssh/ssh_socket_factory.dart';

/// Service managing multiple simultaneous SSH connection sessions keyed by session ID.
///
/// Contains NO Flutter imports (pure Dart) for 100% testability with `dart test`.
class SSHConnectionService {
  SSHConnectionService({
    required this.hostKeyVerifier,
    this.socketFactory = const DefaultSSHSocketFactory(),
    this.connectTimeout = const Duration(seconds: 10),
    this.keepAliveInterval = const Duration(seconds: 15),
    this.reconnectDelays = const [
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
    ],
  });

  final HostKeyVerifier hostKeyVerifier;
  final SSHSocketFactory socketFactory;
  final Duration connectTimeout;
  final Duration keepAliveInterval;
  final List<Duration> reconnectDelays;

  final Map<String, SSHConnectionSession> _sessions = {};

  /// Returns an existing session or creates a new one for [sessionId].
  SSHConnectionSession getOrCreateSession(
    String sessionId,
    ServerConfig server,
  ) {
    var session = _sessions[sessionId];
    if (session == null || session.server.id != server.id) {
      session?.dispose();
      session = SSHConnectionSession(
        sessionId: sessionId,
        server: server,
        hostKeyVerifier: hostKeyVerifier,
        socketFactory: socketFactory,
        connectTimeout: connectTimeout,
        keepAliveInterval: keepAliveInterval,
        reconnectDelays: reconnectDelays,
      );
      _sessions[sessionId] = session;
    }
    return session;
  }

  /// Returns the session for [sessionId] if it exists.
  SSHConnectionSession? getSession(String sessionId) {
    return _sessions[sessionId];
  }

  /// Closes and disposes the session identified by [sessionId].
  void closeSession(String sessionId) {
    final session = _sessions.remove(sessionId);
    session?.dispose();
  }

  /// Disposes all active sessions.
  void dispose() {
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
  }
}
