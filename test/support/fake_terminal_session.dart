import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/services/ssh/host_key_verifier.dart';
import 'package:ssh_app/services/ssh/ssh_connection_service.dart';
import 'package:ssh_app/services/ssh/ssh_connection_session.dart';

HostKeyVerifier noKnownHosts() {
  return HostKeyVerifier(
    findKnownHost: (host, port) async => null,
    saveKnownHost: (host) async {},
  );
}

/// A shell whose output and end the test controls.
class FakeShell implements SSHSession {
  final _stdout = StreamController<Uint8List>();
  final _done = Completer<void>();
  var closed = false;

  void emit(String text) {
    _stdout.add(Uint8List.fromList(utf8.encode(text)));
  }

  /// Ends the shell, as `exit` or a dropped connection does.
  void end() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void close() {
    closed = true;
    end();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An open SSH connection, as far as the terminal can tell.
class FakeClient implements SSHClient {
  @override
  var isClosed = false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A session that records what the terminal sends it, with no network.
class RecordingSession extends SSHConnectionSession {
  RecordingSession(ServerConfig server)
    : super(
        sessionId: 'session-1',
        server: server,
        hostKeyVerifier: noKnownHosts(),
      );

  final writes = <List<int>>[];
  final resizes =
      <({int columns, int rows, int pixelWidth, int pixelHeight})>[];
  final openedShells = <({int columns, int rows})>[];
  final shells = <FakeShell>[];
  var connected = false;
  SSHClient? fakeClient;

  /// Everything written so far, as text.
  String get written =>
      utf8.decode([for (final chunk in writes) ...chunk], allowMalformed: true);

  @override
  bool get isConnected => connected;

  @override
  SSHClient? get client => fakeClient;

  @override
  void writeShell(List<int> data) {
    writes.add(List.of(data));
  }

  @override
  void resizeShell(
    int columns,
    int rows, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) {
    resizes.add((
      columns: columns,
      rows: rows,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    ));
  }

  @override
  Future<SSHSession> openShell({int columns = 80, int rows = 24}) async {
    openedShells.add((columns: columns, rows: rows));
    final shell = FakeShell();
    shells.add(shell);
    return shell;
  }
}

/// A service that hands out one prepared session.
class SingleSessionService extends SSHConnectionService {
  SingleSessionService(this.session) : super(hostKeyVerifier: noKnownHosts());

  final SSHConnectionSession session;

  @override
  SSHConnectionSession? getSession(String sessionId) => session;

  @override
  SSHConnectionSession getOrCreateSession(
    String sessionId,
    ServerConfig server,
  ) {
    return session;
  }
}

/// A service with a separate [RecordingSession] for every session ID.
class MultiSessionService extends SSHConnectionService {
  MultiSessionService() : super(hostKeyVerifier: noKnownHosts());

  final sessions = <String, RecordingSession>{};

  @override
  SSHConnectionSession? getSession(String sessionId) {
    return sessions.putIfAbsent(
      sessionId,
      () => RecordingSession(
        ServerConfig.create(
          label: 'x',
          host: 'x.example.com',
          username: 'x',
          authType: AuthType.password,
        ),
      )..connected = true,
    );
  }

  @override
  SSHConnectionSession getOrCreateSession(
    String sessionId,
    ServerConfig server,
  ) => getSession(sessionId)!;
}
