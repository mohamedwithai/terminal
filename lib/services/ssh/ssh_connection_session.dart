import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.js_interop) 'package:ssh_app/services/ssh/io_stub.dart';

import 'package:dartssh2/dartssh2.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/services/ssh/host_key_verifier.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';
import 'package:ssh_app/services/ssh/ssh_errors.dart';
import 'package:ssh_app/services/ssh/ssh_socket_factory.dart';

/// Manages the connection lifecycle for a single SSH session.
class SSHConnectionSession {
  SSHConnectionSession({
    required this.sessionId,
    required this.server,
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

  final String sessionId;
  final ServerConfig server;
  final HostKeyVerifier hostKeyVerifier;
  final SSHSocketFactory socketFactory;
  final Duration connectTimeout;
  final Duration keepAliveInterval;
  final List<Duration> reconnectDelays;

  final _stateController = StreamController<SSHConnectionState>.broadcast();
  SSHConnectionState _state = const SSHConnectionState.disconnected();

  SSHClient? _client;
  ServerCredentials? _credentials;
  bool _intentionalDisconnect = false;
  bool _isDisposed = false;
  Timer? _reconnectTimer;

  SSHConnectionState get state => _state;
  Stream<SSHConnectionState> get stateStream => _stateController.stream;
  bool get isConnected => _state.status == SSHConnectionStatus.connected;
  SSHClient? get client => _client;

  void _emit(SSHConnectionState newState) {
    if (_isDisposed) return;
    _state = newState;
    _stateController.add(newState);
  }

  /// Initiates an SSH connection using the provided credentials.
  Future<void> connect(ServerCredentials credentials) async {
    _credentials = credentials;
    _intentionalDisconnect = false;
    _reconnectTimer?.cancel();

    _emit(const SSHConnectionState.connecting());

    try {
      await _establishConnection(credentials);
    } catch (e) {
      final sshError = _mapException(e);
      _emit(SSHConnectionState.error(sshError.message, sshError));
      rethrow;
    }
  }

  Future<void> _establishConnection(ServerCredentials credentials) async {
    // 1. Prepare authentication identities
    List<SSHKeyPair>? identities;
    if (server.authType == AuthType.privateKey) {
      final keyPem = credentials.privateKey?.trim() ?? '';
      if (keyPem.isEmpty) {
        throw const SSHAuthFailedException('Missing private key for authentication.');
      }
      try {
        identities = SSHKeyPair.fromPem(
          keyPem,
          credentials.passphrase?.isNotEmpty == true ? credentials.passphrase : null,
        );
        if (identities.isEmpty) {
          throw const SSHAuthFailedException('Invalid private key format.');
        }
      } catch (e) {
        throw SSHAuthFailedException('Could not parse private key: $e', e);
      }
    }

    // 2. Connect TCP socket with timeout
    final SSHSocket socket;
    try {
      socket = await socketFactory
          .connect(
            server.host,
            server.port,
            timeout: connectTimeout,
          )
          .timeout(connectTimeout);
    } on TimeoutException catch (e) {
      throw SSHTimeoutException('Connection timed out after ${connectTimeout.inSeconds}s.', e);
    } catch (e) {
      throw _mapException(e);
    }

    // 3. Create SSH Client with TOFU verifier and keepalive
    SSHHostKeyChangedException? hostKeyChangedError;
    bool hostKeyRejected = false;

    final client = SSHClient(
      socket,
      username: server.username,
      onPasswordRequest: () {
        if (server.authType == AuthType.password) {
          return credentials.password ?? '';
        }
        return '';
      },
      identities: identities,
      keepAliveInterval: keepAliveInterval,
      onVerifyHostKey: (type, fingerprintBytes) async {
        try {
          return await hostKeyVerifier.verify(
            host: server.host,
            port: server.port,
            keyType: type,
            fingerprintBytes: fingerprintBytes,
            onChallenge: (challenge) async {
              _emit(SSHConnectionState.awaitingHostKeyConfirmation(challenge));
              final result = await challenge.decision;
              if (!result) {
                hostKeyRejected = true;
              }
              return result;
            },
          );
        } on SSHHostKeyChangedException catch (e) {
          hostKeyChangedError = e;
          return false;
        } catch (_) {
          return false;
        }
      },
    );

    // 4. Authenticate
    try {
      await client.authenticated.timeout(connectTimeout);
    } catch (e) {
      client.close();
      if (hostKeyChangedError != null) {
        throw hostKeyChangedError!;
      }
      if (hostKeyRejected) {
        throw const SSHHostKeyRejectedException('Host key was rejected by the user.');
      }
      throw _mapAuthException(e);
    }

    _client = client;
    _emit(const SSHConnectionState.connected());

    // 5. Monitor unexpected disconnection
    unawaited(_monitorSession(client));
  }

  Future<void> _monitorSession(SSHClient activeClient) async {
    try {
      await activeClient.done;
    } catch (_) {
      // Disconnection error caught below
    }

    if (_client != activeClient || _intentionalDisconnect || _isDisposed) {
      return;
    }

    _client = null;
    // Unexpected drop: trigger reconnect loop
    _startReconnect();
  }

  void _startReconnect() {
    if (_intentionalDisconnect || _isDisposed || _credentials == null) {
      _emit(const SSHConnectionState.disconnected());
      return;
    }

    _reconnectAttempt(0);
  }

  void _reconnectAttempt(int attemptIndex) {
    if (_intentionalDisconnect || _isDisposed || _credentials == null) {
      _emit(const SSHConnectionState.disconnected());
      return;
    }

    if (attemptIndex >= reconnectDelays.length) {
      const error = SSHUnexpectedDisconnectException(
        'Connection lost and could not be re-established after 3 attempts.',
      );
      _emit(SSHConnectionState.error(error.message, error));
      return;
    }

    final attemptNumber = attemptIndex + 1;
    final delay = reconnectDelays[attemptIndex];
    _emit(SSHConnectionState.reconnecting(
      reconnectAttempt: attemptNumber,
      maxReconnectAttempts: reconnectDelays.length,
    ));

    _reconnectTimer = Timer(delay, () async {
      if (_intentionalDisconnect || _isDisposed || _credentials == null) {
        return;
      }
      try {
        await _establishConnection(_credentials!);
      } on SSHAuthFailedException catch (e) {
        // Never retry on auth failures
        _emit(SSHConnectionState.error(e.message, e));
      } on SSHHostKeyChangedException catch (e) {
        // Never retry on host key changes
        _emit(SSHConnectionState.error(e.message, e));
      } catch (_) {
        // Retry next attempt
        _reconnectAttempt(attemptIndex + 1);
      }
    });
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
  Future<void> disconnect() async {
    _intentionalDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    final client = _client;
    _client = null;
    client?.close();

    _emit(const SSHConnectionState.disconnected());
  }

  void dispose() {
    _isDisposed = true;
    _intentionalDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _client?.close();
    _client = null;
    _stateController.close();
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
      if (msg.contains('unreachable') || osMsg.contains('unreachable')) {
        return SSHUnreachableException('Network unreachable to ${server.host}.', error);
      }
      return SSHConnectionRefusedException('Socket error: ${error.message}', error);
    }
    return SSHUnexpectedDisconnectException('Unexpected error: $error', error);
  }

  SSHConnectionException _mapAuthException(Object error) {
    if (error is SSHConnectionException) {
      return error;
    }
    return SSHAuthFailedException('Authentication failed for ${server.username}@${server.host}.', error);
  }
}
