import 'dart:async';

import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/services/ssh/host_key_verifier.dart';
import 'package:ssh_app/services/ssh/reconnect_gate.dart';
import 'package:ssh_app/services/ssh/ssh_connection_session.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';
import 'package:ssh_app/services/ssh/ssh_socket_factory.dart';

/// Service managing multiple simultaneous SSH connection sessions keyed by session ID.
///
/// Contains NO Flutter imports (pure Dart) for 100% testability with `dart test`.
class SSHConnectionService {
  SSHConnectionService({
    required this.hostKeyVerifier,
    this.socketFactory = const DefaultSSHSocketFactory(),
    this.connectTimeout = const Duration(seconds: 10),
    this.handshakeTimeout = const Duration(seconds: 30),
    this.credentialsTimeout = const Duration(seconds: 10),
    this.shellTimeout = const Duration(seconds: 15),
    this.keepAliveInterval = const Duration(seconds: 15),
    this.reconnectDelays = const [
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
    ],
    ReconnectGate? reconnectGate,
  }) : reconnectGate = reconnectGate ?? ReconnectGate();

  final HostKeyVerifier hostKeyVerifier;
  final SSHSocketFactory socketFactory;
  final Duration connectTimeout;
  final Duration handshakeTimeout;
  final Duration credentialsTimeout;
  final Duration shellTimeout;
  final Duration keepAliveInterval;
  final List<Duration> reconnectDelays;

  /// Shared by every session: reconnects wait while the app is in the
  /// background or offline.
  final ReconnectGate reconnectGate;

  final Map<String, SSHConnectionSession> _sessions = {};
  final Map<String, StreamSubscription<SSHConnectionState>> _stateSubs = {};
  final _changes = StreamController<void>.broadcast();

  /// Emits whenever a session is opened, closed or changes state.
  Stream<void> get changes => _changes.stream;

  /// Sessions that are connected, or getting a lost connection back.
  List<SSHConnectionSession> get activeSessions => [
    for (final session in _sessions.values)
      if (session.isActive) session,
  ];

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
        handshakeTimeout: handshakeTimeout,
        credentialsTimeout: credentialsTimeout,
        shellTimeout: shellTimeout,
        keepAliveInterval: keepAliveInterval,
        reconnectDelays: reconnectDelays,
        reconnectGate: reconnectGate,
      );
      _sessions[sessionId] = session;
      unawaited(_stateSubs.remove(sessionId)?.cancel());
      _stateSubs[sessionId] = session.stateStream.listen((_) => _notify());
      _notify();
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
    unawaited(_stateSubs.remove(sessionId)?.cancel());
    session?.dispose();
    if (session != null) {
      _notify();
    }
  }

  /// Disconnects every session, for example from the notification.
  Future<void> disconnectAll() async {
    for (final session in _sessions.values.toList()) {
      await session.disconnect();
    }
  }

  void _notify() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  /// Disposes all active sessions.
  void dispose() {
    for (final sub in _stateSubs.values) {
      unawaited(sub.cancel());
    }
    _stateSubs.clear();
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
    _changes.close();
  }
}
