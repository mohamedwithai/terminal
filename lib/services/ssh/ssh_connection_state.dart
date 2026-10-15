import 'dart:async';
import 'package:ssh_app/services/ssh/ssh_errors.dart';

enum SSHConnectionStatus {
  disconnected,
  connecting,
  awaitingHostKeyConfirmation,
  connected,
  reconnecting,
  error,
}

/// Information presented to the user when a previously unknown host key is encountered.
class HostKeyChallenge {
  HostKeyChallenge({
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprint,
    required this.completer,
  });

  final String host;
  final int port;
  final String keyType;
  final String fingerprint;
  final Completer<bool> completer;

  Future<bool> get decision => completer.future;
  bool get isCompleted => completer.isCompleted;

  void accept() {
    if (!completer.isCompleted) {
      completer.complete(true);
    }
  }

  void reject() {
    if (!completer.isCompleted) {
      completer.complete(false);
    }
  }
}

/// Immutable snapshot of an SSH connection's status.
class SSHConnectionState {
  const SSHConnectionState({
    required this.status,
    this.challenge,
    this.reconnectAttempt = 0,
    this.maxReconnectAttempts = 3,
    this.error,
    this.errorMessage,
  });

  const SSHConnectionState.disconnected()
      : status = SSHConnectionStatus.disconnected,
        challenge = null,
        reconnectAttempt = 0,
        maxReconnectAttempts = 3,
        error = null,
        errorMessage = null;

  const SSHConnectionState.connecting()
      : status = SSHConnectionStatus.connecting,
        challenge = null,
        reconnectAttempt = 0,
        maxReconnectAttempts = 3,
        error = null,
        errorMessage = null;

  const SSHConnectionState.awaitingHostKeyConfirmation(
    HostKeyChallenge this.challenge,
  )   : status = SSHConnectionStatus.awaitingHostKeyConfirmation,
        reconnectAttempt = 0,
        maxReconnectAttempts = 3,
        error = null,
        errorMessage = null;

  const SSHConnectionState.connected()
      : status = SSHConnectionStatus.connected,
        challenge = null,
        reconnectAttempt = 0,
        maxReconnectAttempts = 3,
        error = null,
        errorMessage = null;

  const SSHConnectionState.reconnecting({
    required this.reconnectAttempt,
    this.maxReconnectAttempts = 3,
  })  : status = SSHConnectionStatus.reconnecting,
        challenge = null,
        error = null,
        errorMessage = null;

  const SSHConnectionState.error(
    String message, [
    this.error,
  ])  : status = SSHConnectionStatus.error,
        challenge = null,
        reconnectAttempt = 0,
        maxReconnectAttempts = 3,
        errorMessage = message;

  final SSHConnectionStatus status;
  final HostKeyChallenge? challenge;
  final int reconnectAttempt;
  final int maxReconnectAttempts;
  final SSHConnectionException? error;
  final String? errorMessage;

  bool get isConnected => status == SSHConnectionStatus.connected;
  bool get isConnecting =>
      status == SSHConnectionStatus.connecting ||
      status == SSHConnectionStatus.reconnecting;
  bool get isDisconnected => status == SSHConnectionStatus.disconnected;
  bool get hasError => status == SSHConnectionStatus.error;

  @override
  String toString() {
    return switch (status) {
      SSHConnectionStatus.disconnected => 'disconnected',
      SSHConnectionStatus.connecting => 'connecting',
      SSHConnectionStatus.awaitingHostKeyConfirmation =>
        'awaitingHostKeyConfirmation(${challenge?.fingerprint})',
      SSHConnectionStatus.connected => 'connected',
      SSHConnectionStatus.reconnecting =>
        'reconnecting($reconnectAttempt/$maxReconnectAttempts)',
      SSHConnectionStatus.error => 'error($errorMessage)',
    };
  }
}
