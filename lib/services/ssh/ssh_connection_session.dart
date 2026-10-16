import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.js_interop) 'package:ssh_app/services/ssh/io_stub.dart';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/services/ssh/connection_log.dart';
import 'package:ssh_app/services/ssh/host_key_verifier.dart';
import 'package:ssh_app/services/ssh/pausable_deadline.dart';
import 'package:ssh_app/services/ssh/reconnect_gate.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';
import 'package:ssh_app/services/ssh/ssh_errors.dart';
import 'package:ssh_app/services/ssh/ssh_socket_factory.dart';

/// Supplies the credentials for a connection attempt, or null if none are
/// saved.
typedef CredentialsLoader = FutureOr<ServerCredentials?> Function();

/// Manages the connection lifecycle for a single SSH session.
class SSHConnectionSession {
  SSHConnectionSession({
    required this.sessionId,
    required this.server,
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
    ConnectionLog? log,
  }) : reconnectGate = reconnectGate ?? ReconnectGate(),
       log = log ?? ConnectionLog();

  final String sessionId;
  final ServerConfig server;
  final HostKeyVerifier hostKeyVerifier;
  final SSHSocketFactory socketFactory;

  /// Limit for opening the TCP connection.
  final Duration connectTimeout;

  /// One limit for everything after the TCP connection opens: key exchange,
  /// host key verification and authentication. It stops counting while the
  /// user decides on an unknown host key.
  final Duration handshakeTimeout;

  /// Limit for reading the credentials from secure storage.
  final Duration credentialsTimeout;

  /// Limit for opening the interactive shell.
  final Duration shellTimeout;

  final Duration keepAliveInterval;
  final List<Duration> reconnectDelays;

  /// Holds reconnect attempts back while the app is in the background or
  /// offline.
  final ReconnectGate reconnectGate;

  /// What this session did, step by step. Never contains secrets.
  final ConnectionLog log;

  final _stateController = StreamController<SSHConnectionState>.broadcast();
  SSHConnectionState _state = const SSHConnectionState.disconnected();

  SSHClient? _client;
  SSHSession? _shell;
  Future<SSHSession>? _openingShell;
  ServerCredentials? _credentials;
  bool _intentionalDisconnect = false;
  bool _isDisposed = false;
  Timer? _reconnectTimer;

  /// Index into [reconnectDelays] of the next attempt while a lost
  /// connection is being re-established, otherwise null.
  int? _reconnectIndex;
  StreamSubscription<void>? _gateSub;

  /// What the reconnect is waiting for, while it waits for [reconnectGate].
  String? _waitingFor;

  /// Incremented whenever an attempt starts or is abandoned. Callbacks from
  /// an older attempt compare against it and stop touching state.
  int _attempt = 0;

  /// Client of the attempt in flight, before it has authenticated.
  SSHClient? _connectingClient;

  /// Unknown host key the user has not decided on yet.
  HostKeyChallenge? _pendingChallenge;

  /// Step the attempt in flight is on.
  SSHConnectionStage? _stage;

  SSHConnectionState get state => _state;
  Stream<SSHConnectionState> get stateStream => _stateController.stream;
  bool get isConnected => _state.status == SSHConnectionStatus.connected;

  /// Connected, or getting a lost connection back.
  bool get isActive =>
      _state.status == SSHConnectionStatus.connected ||
      _state.status == SSHConnectionStatus.reconnecting;

  SSHClient? get client => _client;

  /// The interactive PTY shell, once [openShell] has succeeded.
  SSHSession? get shell => _shell;

  void _emit(SSHConnectionState newState) {
    if (_isDisposed) return;
    _state = newState;
    _stateController.add(newState);
  }

  /// Initiates an SSH connection using the provided credentials.
  Future<void> connect(ServerCredentials credentials) {
    return connectWith(() => credentials);
  }

  /// Loads credentials with [loadCredentials], then connects.
  ///
  /// Every failure, including one while loading the credentials, ends in an
  /// [SSHConnectionStatus.error] state and is rethrown as an
  /// [SSHConnectionException].
  Future<void> connectWith(CredentialsLoader loadCredentials) async {
    _intentionalDisconnect = false;
    _stopReconnecting();
    _abandonAttempt();
    final attempt = _attempt;

    log.add('Connecting to ${server.username}@${server.host}:${server.port}');
    _stage = SSHConnectionStage.loadingCredentials;
    _emit(const SSHConnectionState.connecting(
      SSHConnectionStage.loadingCredentials,
    ));
    try {
      final credentials = await _loadCredentials(loadCredentials);
      _checkCurrent(attempt);
      _credentials = credentials;
      await _establishConnection(attempt, credentials);
    } catch (error, stackTrace) {
      final failure = _recordFailure(attempt, error);
      if (_isCurrent(attempt)) {
        _emit(SSHConnectionState.error(
          failure.error.message,
          failure.error,
          failure.stage,
        ));
      }
      Error.throwWithStackTrace(failure.error, stackTrace);
    }
  }

  Future<ServerCredentials> _loadCredentials(CredentialsLoader load) async {
    log.add('Reading saved credentials');
    final ServerCredentials? credentials;
    try {
      credentials = await Future.sync(load).timeout(credentialsTimeout);
    } on TimeoutException catch (e) {
      throw SSHCredentialsException(
        'Reading the saved credentials from secure storage took longer than '
        '${_formatDuration(credentialsTimeout)}.',
        e,
      );
    } on SSHConnectionException {
      rethrow;
    } catch (e) {
      throw SSHCredentialsException(
        'Could not read the saved credentials from secure storage: $e',
        e,
      );
    }
    if (credentials == null) {
      throw const SSHCredentialsException(
        'No saved credentials were found for this server. '
        'Edit the server and enter them again.',
      );
    }
    return credentials;
  }

  Future<void> _establishConnection(
    int attempt,
    ServerCredentials credentials,
  ) async {
    _closeShell();

    // 1. Prepare authentication identities
    final identities = _decodeIdentities(credentials);

    // 2. Open the TCP connection
    _enterStage(attempt, SSHConnectionStage.openingConnection);
    log.add(
      'Opening TCP connection to ${server.host}:${server.port} '
      '(limit ${_formatDuration(connectTimeout)})',
    );
    final socket = await _openSocket();
    if (!_isCurrent(attempt)) {
      socket.destroy();
      _checkCurrent(attempt);
    }
    log.add('TCP connection open');

    // 3. Key exchange, host key check and authentication share one limit,
    // which pauses while the user decides on an unknown host key.
    _enterStage(attempt, SSHConnectionStage.exchangingKeys);
    log.add(
      'Exchanging keys (limit ${_formatDuration(handshakeTimeout)} for key '
      'exchange and sign-in; it pauses while you check a new host key)',
    );
    final deadline = PausableDeadline(handshakeTimeout);

    SSHHostKeyChangedException? hostKeyChangedError;
    Object? hostKeyCheckError;
    var hostKeyRejected = false;
    // Set once this attempt has an outcome, so late callbacks stay quiet.
    var settled = false;

    final client = SSHClient(
      socket,
      username: server.username,
      printDebug: (message) {
        if (message == null || settled || !_isCurrent(attempt)) return;
        if (_noisyDebug.any(message.startsWith)) return;
        log.add('ssh: $message');
      },
      onPasswordRequest: () {
        if (server.authType == AuthType.password) {
          return credentials.password ?? '';
        }
        return '';
      },
      identities: identities,
      keepAliveInterval: keepAliveInterval,
      onVerifyHostKey: (type, fingerprintBytes) async {
        if (settled || !_isCurrent(attempt)) return false;
        _enterStage(attempt, SSHConnectionStage.verifyingHostKey);
        log.add(
          'Server host key: $type '
          '${HostKeyVerifier.formatFingerprint(fingerprintBytes)}',
        );
        var askedUser = false;
        try {
          final accepted = await hostKeyVerifier.verify(
            host: server.host,
            port: server.port,
            keyType: type,
            fingerprintBytes: fingerprintBytes,
            onChallenge: (challenge) async {
              if (settled || !_isCurrent(attempt)) return false;
              askedUser = true;
              _pendingChallenge = challenge;
              log.add(
                'Host key is not saved yet. Waiting for you to accept or '
                'reject it; sign-in waits until then.',
              );
              _emit(SSHConnectionState.awaitingHostKeyConfirmation(challenge));
              deadline.pause();
              final bool decision;
              try {
                decision = await challenge.decision;
              } finally {
                deadline.resume();
              }
              if (identical(_pendingChallenge, challenge)) {
                _pendingChallenge = null;
              }
              if (settled || !_isCurrent(attempt)) return false;
              if (decision) {
                log.add('Host key accepted');
              } else {
                hostKeyRejected = true;
                log.add('Host key rejected', isError: true);
              }
              return decision;
            },
          );
          if (!accepted || settled || !_isCurrent(attempt)) return false;
          log.add(askedUser ? 'Host key saved' : 'Host key matches the saved key');
          _enterStage(attempt, SSHConnectionStage.authenticating);
          log.add(
            'Authenticating as ${server.username} '
            '(${identities == null ? 'password' : 'private key'})',
          );
          return true;
        } on SSHHostKeyChangedException catch (e) {
          hostKeyChangedError = e;
          return false;
        } catch (e) {
          hostKeyCheckError = e;
          return false;
        }
      },
    );
    _connectingClient = client;

    // 4. Wait for authentication
    try {
      final timedOut = await Future.any<bool>([
        client.authenticated.then((_) => false),
        deadline.expired.then((_) => true),
      ]);
      if (timedOut) {
        throw TimeoutException('SSH handshake', handshakeTimeout);
      }
    } catch (e) {
      deadline.cancel();
      settled = true;
      final waitingForUser = _pendingChallenge != null;
      if (_isCurrent(attempt)) {
        // A late Accept must not save the key of an attempt that is over.
        _pendingChallenge?.reject();
        _pendingChallenge = null;
      }
      if (identical(_connectingClient, client)) {
        _connectingClient = null;
      }
      client.close();
      _checkCurrent(attempt);

      if (e is TimeoutException) {
        throw SSHTimeoutException(_handshakeTimeoutMessage(waitingForUser), e);
      }
      if (hostKeyChangedError != null) {
        throw hostKeyChangedError!;
      }
      if (hostKeyRejected) {
        throw const SSHHostKeyRejectedException('Host key was rejected by the user.');
      }
      if (hostKeyCheckError != null) {
        throw SSHHandshakeException(
          'Could not check the host key against the saved keys: '
          '$hostKeyCheckError',
          hostKeyCheckError,
        );
      }
      throw _mapHandshakeException(e);
    }

    deadline.cancel();
    settled = true;
    if (identical(_connectingClient, client)) {
      _connectingClient = null;
    }
    if (!_isCurrent(attempt)) {
      client.close();
      _checkCurrent(attempt);
    }

    _client = client;
    _stage = null;
    log.add('Signed in');
    _emit(const SSHConnectionState.connected());

    // 5. Monitor unexpected disconnection
    unawaited(_monitorSession(client));
  }

  List<SSHKeyPair>? _decodeIdentities(ServerCredentials credentials) {
    if (server.authType != AuthType.privateKey) {
      return null;
    }
    final keyPem = credentials.privateKey?.trim() ?? '';
    if (keyPem.isEmpty) {
      throw const SSHAuthFailedException('Missing private key for authentication.');
    }
    log.add('Decoding private key');
    final List<SSHKeyPair> identities;
    try {
      identities = SSHKeyPair.fromPem(
        keyPem,
        credentials.passphrase?.isNotEmpty == true ? credentials.passphrase : null,
      );
    } catch (e) {
      throw SSHAuthFailedException('Could not parse private key: $e', e);
    }
    if (identities.isEmpty) {
      throw const SSHAuthFailedException('Invalid private key format.');
    }
    log.add('Private key decoded (${identities.first.type})');
    return identities;
  }

  Future<SSHSocket> _openSocket() async {
    final pending = socketFactory.connect(
      server.host,
      server.port,
      timeout: connectTimeout,
    );
    try {
      return await pending.timeout(connectTimeout);
    } on TimeoutException catch (e) {
      // The connect may still succeed later; do not leak that socket.
      unawaited(pending.then<void>(
        (socket) => socket.destroy(),
        onError: (Object _) {},
      ));
      throw SSHTimeoutException(_tcpTimeoutMessage(), e);
    } catch (e) {
      throw _mapException(e);
    }
  }

  Future<void> _monitorSession(SSHClient activeClient) async {
    Object? error;
    try {
      await activeClient.done;
    } catch (e) {
      error = e;
    }

    if (_client != activeClient || _intentionalDisconnect || _isDisposed) {
      return;
    }

    log.add(
      error == null
          ? 'Connection closed by the server'
          : 'Connection lost: ${describeError(error)}',
      isError: true,
    );
    _client = null;
    // Unexpected drop: trigger reconnect loop
    _startReconnect();
  }

  /// Drives the reconnect loop as if the connection had just dropped, so
  /// tests can exercise it without an SSH server.
  void debugSimulateConnectionLost(ServerCredentials credentials) {
    _intentionalDisconnect = false;
    _credentials = credentials;
    log.add('Connection lost (simulated)', isError: true);
    _startReconnect();
  }

  void _startReconnect() {
    if (_intentionalDisconnect || _isDisposed || _credentials == null) {
      _emit(const SSHConnectionState.disconnected());
      return;
    }
    _reconnectIndex = 0;
    _gateSub ??= reconnectGate.changes.listen((_) => _onGateChanged());
    _scheduleReconnect();
  }

  void _stopReconnecting() {
    _reconnectIndex = null;
    _waitingFor = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _gateSub?.cancel();
    _gateSub = null;
  }

  /// Schedules the next attempt, or waits while [reconnectGate] is closed.
  void _scheduleReconnect() {
    final index = _reconnectIndex;
    if (index == null || _isDisposed) {
      return;
    }
    if (!reconnectGate.isOpen) {
      _waitForGate();
      return;
    }
    _waitingFor = null;

    if (index >= reconnectDelays.length) {
      _stopReconnecting();
      final error = SSHUnexpectedDisconnectException(
        'Connection lost and could not be re-established after '
        '${reconnectDelays.length} attempts.',
      );
      log.add(error.message, isError: true);
      _emit(SSHConnectionState.error(error.message, error));
      return;
    }

    final attemptNumber = index + 1;
    final delay = reconnectDelays[index];
    log.add(
      'Reconnecting in ${_formatDuration(delay)} '
      '(attempt $attemptNumber of ${reconnectDelays.length})',
    );
    _emit(SSHConnectionState.reconnecting(
      reconnectAttempt: attemptNumber,
      maxReconnectAttempts: reconnectDelays.length,
    ));
    _reconnectTimer = Timer(delay, _runReconnectAttempt);
  }

  /// Holds the reconnect until [reconnectGate] opens. No attempt is spent.
  void _waitForGate() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final reason = reconnectGate.waitingFor;
    if (reason == _waitingFor) {
      return;
    }
    _waitingFor = reason;
    log.add('Waiting for $reason before reconnecting');
    _emit(SSHConnectionState.reconnecting(
      reconnectAttempt: 0,
      maxReconnectAttempts: reconnectDelays.length,
      waitingFor: reason,
    ));
  }

  void _onGateChanged() {
    if (_reconnectIndex == null || _isDisposed) {
      return;
    }
    if (reconnectGate.isOpen) {
      if (_waitingFor != null) {
        // Whatever failed before was down to the background or the network,
        // so the reconnect starts over with every attempt.
        log.add('Ready to reconnect');
        _reconnectIndex = 0;
        _scheduleReconnect();
      }
    } else if (_waitingFor != null || _reconnectTimer != null) {
      // Waiting already, or an attempt is scheduled but has not started. An
      // attempt in flight is left to finish; if it fails it is not counted.
      _waitForGate();
    }
  }

  Future<void> _runReconnectAttempt() async {
    _reconnectTimer = null;
    final index = _reconnectIndex;
    final credentials = _credentials;
    if (index == null ||
        credentials == null ||
        _intentionalDisconnect ||
        _isDisposed) {
      return;
    }
    _abandonAttempt();
    final attempt = _attempt;
    try {
      await _establishConnection(attempt, credentials);
      if (_isCurrent(attempt)) {
        _stopReconnecting();
      }
    } catch (error) {
      final failure = _recordFailure(attempt, error);
      if (!_isCurrent(attempt) || _reconnectIndex == null) {
        return;
      }
      final e = failure.error;
      if (e is SSHAuthFailedException || e is SSHHostKeyChangedException) {
        // Never retry on auth failures or host key changes
        _stopReconnecting();
        _emit(SSHConnectionState.error(e.message, e, failure.stage));
        return;
      }
      if (!reconnectGate.isOpen) {
        // It failed because the app went to the background or offline.
        _waitForGate();
        return;
      }
      _reconnectIndex = index + 1;
      _scheduleReconnect();
    }
  }

  /// Returns the interactive shell, opening one if there is none.
  ///
  /// A shell that is already open is resized to [columns]x[rows] and
  /// returned, so the status screen can open it and the terminal can take it
  /// over. A second call while one is opening waits for that one. The shell
  /// is closed when the connection is rebuilt.
  Future<SSHSession> openShell({
    int columns = 80,
    int rows = 24,
  }) {
    final pending = _openingShell;
    if (pending != null) {
      return pending;
    }
    final open = _shell;
    if (open != null) {
      resizeShell(columns, rows);
      return Future.value(open);
    }
    final future = _openShell(columns: columns, rows: rows);
    _openingShell = future;
    return future.whenComplete(() {
      if (identical(_openingShell, future)) {
        _openingShell = null;
      }
    });
  }

  Future<SSHSession> _openShell({
    required int columns,
    required int rows,
  }) async {
    final client = _client;
    if (client == null || !isConnected) {
      throw const SSHUnexpectedDisconnectException(
        'Cannot open a shell: not connected.',
      );
    }
    final width = columns < 1 ? 80 : columns;
    final height = rows < 1 ? 24 : rows;
    log.add('Opening shell (xterm-256color, ${width}x$height)');

    final pending = client.shell(
      pty: SSHPtyConfig(type: 'xterm-256color', width: width, height: height),
    );
    final SSHSession shell;
    try {
      shell = await pending.timeout(shellTimeout);
    } on TimeoutException catch (e) {
      unawaited(pending.then<void>(
        (orphan) => orphan.close(),
        onError: (Object _) {},
      ));
      final error = SSHTimeoutException(
        'Timed out after ${_formatDuration(shellTimeout)} opening the shell. '
        'The server did not answer the shell request.',
        e,
      );
      log.add(error.message, isError: true);
      throw error;
    } catch (e) {
      log.add('Could not open the shell: ${describeError(e)}', isError: true);
      rethrow;
    }

    if (!identical(_client, client)) {
      shell.close();
      throw const SSHUnexpectedDisconnectException(
        'The connection closed while the shell was opening.',
      );
    }
    _shell = shell;
    log.add('Shell open');
    unawaited(shell.done.then<void>(
      (_) => _forgetShell(shell),
      onError: (Object _) => _forgetShell(shell),
    ));
    return shell;
  }

  void _forgetShell(SSHSession shell) {
    if (identical(_shell, shell)) {
      _shell = null;
    }
  }

  /// Forwards the local terminal size to the remote PTY.
  void resizeShell(
    int columns,
    int rows, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) {
    _shell?.resizeTerminal(columns, rows, pixelWidth, pixelHeight);
  }

  /// Writes already-encoded terminal input to the remote shell.
  void writeShell(List<int> data) {
    if (data.isEmpty) {
      return;
    }
    _shell?.write(Uint8List.fromList(data));
  }

  void _closeShell() {
    final shell = _shell;
    _shell = null;
    shell?.close();
  }

  /// Runs a command on the active session and returns stdout.
  Future<String> execute(String command) async {
    final client = _client;
    if (client == null || !isConnected) {
      throw const SSHUnexpectedDisconnectException('Cannot execute command: Not connected.');
    }

    final session = await client.execute(command);
    final stdoutFuture = utf8.decodeStream(session.stdout);
    final stderrFuture = utf8.decodeStream(session.stderr);

    final results = await Future.wait([stdoutFuture, stderrFuture]);
    final stdoutText = results[0];
    final stderrText = results[1];

    if (stderrText.isNotEmpty && stdoutText.isEmpty) {
      return stderrText;
    }
    return stdoutText;
  }

  /// Voluntarily closes the connection without triggering automatic reconnect.
  ///
  /// An attempt still in progress is abandoned and its connection closed.
  Future<void> disconnect() async {
    _intentionalDisconnect = true;
    _stopReconnecting();
    _abandonAttempt();

    _closeShell();
    final client = _client;
    _client = null;
    client?.close();

    log.add('Disconnected');
    _emit(const SSHConnectionState.disconnected());
  }

  void dispose() {
    _isDisposed = true;
    _intentionalDisconnect = true;
    _stopReconnecting();
    _abandonAttempt();
    _closeShell();
    _client?.close();
    _client = null;
    _stateController.close();
    log.dispose();
  }

  /// Stops the attempt in flight, if any: its callbacks stop changing state,
  /// an open host key question is answered "reject", and its half-open
  /// connection is closed.
  void _abandonAttempt() {
    _attempt++;
    _stage = null;
    final challenge = _pendingChallenge;
    _pendingChallenge = null;
    challenge?.reject();
    final client = _connectingClient;
    _connectingClient = null;
    client?.close();
  }

  bool _isCurrent(int attempt) => attempt == _attempt && !_isDisposed;

  void _checkCurrent(int attempt) {
    if (!_isCurrent(attempt)) {
      throw const SSHUnexpectedDisconnectException(
        'The connection attempt was cancelled.',
      );
    }
  }

  void _enterStage(int attempt, SSHConnectionStage stage) {
    if (!_isCurrent(attempt)) return;
    _stage = stage;
    if (_state.status == SSHConnectionStatus.reconnecting) {
      _emit(SSHConnectionState.reconnecting(
        reconnectAttempt: _state.reconnectAttempt,
        maxReconnectAttempts: _state.maxReconnectAttempts,
        stage: stage,
      ));
    } else {
      _emit(SSHConnectionState.connecting(stage));
    }
  }

  /// Maps [error], writes it to the log, and returns it with the stage it
  /// happened in. Attempts that were abandoned are not logged.
  ({SSHConnectionException error, SSHConnectionStage? stage}) _recordFailure(
    int attempt,
    Object error,
  ) {
    final mapped = _mapException(error);
    final stage = _stage;
    if (_isCurrent(attempt)) {
      _stage = null;
      final where = stage == null ? '' : ' (${stage.label})';
      log.add('Failed$where: ${mapped.message}', isError: true);
      final cause = mapped.cause;
      if (cause != null) {
        final text = describeError(cause);
        final type = '${cause.runtimeType}';
        log.add(
          'Exception: ${text.startsWith(type) ? text : '$type: $text'}',
          isError: true,
        );
      }
    }
    return (error: mapped, stage: stage);
  }

  String _tcpTimeoutMessage() {
    return 'Could not open a TCP connection to ${server.host}:${server.port} '
        'within ${_formatDuration(connectTimeout)}. Check the address and '
        'port, and that this device can reach the server (same network or '
        'VPN, no firewall in the way).';
  }

  String _handshakeTimeoutMessage(bool waitingForUser) {
    final limit = _formatDuration(handshakeTimeout);
    return switch (_stage) {
      SSHConnectionStage.verifyingHostKey when waitingForUser =>
        'Timed out after $limit waiting for the host key to be accepted.',
      SSHConnectionStage.verifyingHostKey =>
        'Timed out after $limit while checking the host key.',
      SSHConnectionStage.authenticating =>
        'Timed out after $limit while authenticating. '
            'The server did not answer the sign-in request.',
      _ => 'Timed out after $limit while exchanging keys. The TCP connection '
          'opened but the SSH handshake did not finish. Check that '
          '${server.host}:${server.port} is an SSH server.',
    };
  }

  SSHConnectionException _mapHandshakeException(Object error) {
    if (error is SSHConnectionException) {
      return error;
    }
    if (error is SSHAuthFailError) {
      return SSHAuthFailedException(
        'Authentication failed for ${server.username}@${server.host}: '
        '${error.message}',
        error,
      );
    }
    final stage = _stage ?? SSHConnectionStage.exchangingKeys;
    final detail = error is SSHAuthAbortError && error.reason != null
        ? describeError(error.reason!)
        : describeError(error);
    if (stage == SSHConnectionStage.authenticating) {
      return SSHAuthFailedException(
        'The server closed the connection during sign-in: $detail',
        error,
      );
    }
    return SSHHandshakeException(
      'The SSH handshake failed while ${stage.label.toLowerCase()}: $detail',
      error,
    );
  }

  SSHConnectionException _mapException(Object error) {
    if (error is SSHConnectionException) {
      return error;
    }
    if (error is TimeoutException) {
      return SSHTimeoutException('Connection timed out.', error);
    }
    if (error is SocketException) {
      final msg = error.message.toLowerCase();
      final osMsg = error.osError?.message.toLowerCase() ?? '';
      if (msg.contains('failed host lookup') || osMsg.contains('no such host')) {
        return SSHDnsException('DNS lookup failed for ${server.host}.', error);
      }
      if (msg.contains('refused') || osMsg.contains('refused')) {
        return SSHConnectionRefusedException(
          'Connection refused by ${server.host}:${server.port}.',
          error,
        );
      }
      if (msg.contains('timed out') || osMsg.contains('timed out')) {
        return SSHTimeoutException(_tcpTimeoutMessage(), error);
      }
      if (msg.contains('unreachable') ||
          osMsg.contains('unreachable') ||
          osMsg.contains('no route')) {
        return SSHUnreachableException('Network unreachable to ${server.host}.', error);
      }
      return SSHConnectionRefusedException('Socket error: $error', error);
    }
    return SSHUnexpectedDisconnectException('Unexpected error: $error', error);
  }

  /// dartssh2 per-packet debug lines that would drown out the useful ones.
  static const _noisyDebug = [
    'SSHTransport._processPackets',
    'SSHTransport._consumeClearTextPacket',
    'SSHTransport._consumeEncryptedPacket',
  ];

  /// The exception text, including the reason dartssh2 wraps inside an
  /// [SSHAuthAbortError].
  static String describeError(Object error) {
    if (error is SSHAuthAbortError && error.reason != null) {
      return '$error, caused by ${error.reason}';
    }
    return '$error';
  }

  static String _formatDuration(Duration duration) {
    final millis = duration.inMilliseconds;
    return millis % 1000 == 0 ? '${millis ~/ 1000}s' : '${millis}ms';
  }
}
