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

/// The step a connection attempt is on, in the order they happen.
enum SSHConnectionStage {
  loadingCredentials('Loading credentials'),
  openingConnection('Opening connection'),
  exchangingKeys('Exchanging keys'),
  verifyingHostKey('Verifying host key'),
  authenticating('Authenticating'),
  openingShell('Opening shell');

  const SSHConnectionStage(this.label);

  /// Shown on the status screen and in the connection log.
  final String label;
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
    this.stage,
    this.waitingFor,
  });

  const SSHConnectionState.disconnected()
    : status = SSHConnectionStatus.disconnected,
      challenge = null,
      reconnectAttempt = 0,
      maxReconnectAttempts = 3,
      error = null,
      errorMessage = null,
      stage = null,
      waitingFor = null;

  const SSHConnectionState.connecting([
    this.stage = SSHConnectionStage.openingConnection,
  ]) : status = SSHConnectionStatus.connecting,
       challenge = null,
       reconnectAttempt = 0,
       maxReconnectAttempts = 3,
       error = null,
       errorMessage = null,
       waitingFor = null;

  const SSHConnectionState.awaitingHostKeyConfirmation(
    HostKeyChallenge this.challenge,
  ) : status = SSHConnectionStatus.awaitingHostKeyConfirmation,
      reconnectAttempt = 0,
      maxReconnectAttempts = 3,
      error = null,
      errorMessage = null,
      stage = SSHConnectionStage.verifyingHostKey,
      waitingFor = null;

  const SSHConnectionState.connected()
    : status = SSHConnectionStatus.connected,
      challenge = null,
      reconnectAttempt = 0,
      maxReconnectAttempts = 3,
      error = null,
      errorMessage = null,
      stage = null,
      waitingFor = null;

  /// [reconnectAttempt] is 0 while the reconnect waits for [waitingFor].
  const SSHConnectionState.reconnecting({
    required this.reconnectAttempt,
    this.maxReconnectAttempts = 3,
    this.stage,
    this.waitingFor,
  }) : status = SSHConnectionStatus.reconnecting,
       challenge = null,
       error = null,
       errorMessage = null;

  /// [stage] is the step that failed, when the failure happened mid-attempt.
  const SSHConnectionState.error(String message, [this.error, this.stage])
    : status = SSHConnectionStatus.error,
      challenge = null,
      reconnectAttempt = 0,
      maxReconnectAttempts = 3,
      errorMessage = message,
      waitingFor = null;

  final SSHConnectionStatus status;
  final HostKeyChallenge? challenge;
  final int reconnectAttempt;
  final int maxReconnectAttempts;
  final SSHConnectionException? error;
  final String? errorMessage;

  /// The current step while connecting, or the failed step on [error].
  final SSHConnectionStage? stage;

  /// While reconnecting: what the reconnect waits for before its next
  /// attempt, such as a network connection. Null while it is trying.
  final String? waitingFor;

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
      SSHConnectionStatus.connecting => 'connecting(${stage?.label})',
      SSHConnectionStatus.awaitingHostKeyConfirmation =>
        'awaitingHostKeyConfirmation(${challenge?.fingerprint})',
      SSHConnectionStatus.connected => 'connected',
      SSHConnectionStatus.reconnecting when waitingFor != null =>
        'reconnecting(waiting for $waitingFor)',
      SSHConnectionStatus.reconnecting =>
        'reconnecting($reconnectAttempt/$maxReconnectAttempts, ${stage?.label})',
      SSHConnectionStatus.error => 'error($errorMessage)',
    };
  }
}
