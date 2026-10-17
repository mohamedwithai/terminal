/// Base class for all typed SSH connection exceptions.
sealed class SSHConnectionException implements Exception {
  const SSHConnectionException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

/// The connection attempt or handshake exceeded the configured timeout.
class SSHTimeoutException extends SSHConnectionException {
  const SSHTimeoutException([
    super.message = 'Connection timed out.',
    super.cause,
  ]);
}

/// The hostname could not be resolved by DNS.
class SSHDnsException extends SSHConnectionException {
  const SSHDnsException([
    super.message = 'DNS lookup failed. Hostname could not be resolved.',
    super.cause,
  ]);
}

/// Network unreachable or route to host not found.
class SSHUnreachableException extends SSHConnectionException {
  const SSHUnreachableException([
    super.message = 'Network is unreachable or route to host not found.',
    super.cause,
  ]);
}

/// Connection was actively refused by the target host:port.
class SSHConnectionRefusedException extends SSHConnectionException {
  const SSHConnectionRefusedException([
    super.message = 'Connection refused by server.',
    super.cause,
  ]);
}

/// Host key verification rejected because the fingerprint changed.
///
/// Under TOFU, this is a hard error that must never be auto-accepted or bypassed.
class SSHHostKeyChangedException extends SSHConnectionException {
  const SSHHostKeyChangedException({
    required this.host,
    required this.port,
    required this.expectedFingerprint,
    required this.presentedFingerprint,
    required this.keyType,
  }) : super(
         'WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED for $host:$port!\n'
         'Expected: $expectedFingerprint\n'
         'Presented: $presentedFingerprint ($keyType)\n'
         'Someone could be eavesdropping on you (man-in-the-middle attack).',
       );

  final String host;
  final int port;
  final String expectedFingerprint;
  final String presentedFingerprint;
  final String keyType;
}

/// User rejected an unknown host key during first-time connection.
class SSHHostKeyRejectedException extends SSHConnectionException {
  const SSHHostKeyRejectedException([
    super.message = 'Host key was rejected by the user.',
    super.cause,
  ]);
}

/// Authentication failed (incorrect password or rejected private key).
class SSHAuthFailedException extends SSHConnectionException {
  const SSHAuthFailedException([
    super.message = 'Authentication failed. Please verify your credentials.',
    super.cause,
  ]);
}

/// The SSH socket or channel dropped unexpectedly after establishing a connection.
class SSHUnexpectedDisconnectException extends SSHConnectionException {
  const SSHUnexpectedDisconnectException([
    super.message = 'Connection dropped unexpectedly.',
    super.cause,
  ]);
}

/// The SSH handshake failed after the TCP connection was open, for example
/// because the server closed the connection or no algorithms matched.
class SSHHandshakeException extends SSHConnectionException {
  const SSHHandshakeException([
    super.message = 'The SSH handshake failed.',
    super.cause,
  ]);
}

/// The saved credentials could not be read from secure storage.
class SSHCredentialsException extends SSHConnectionException {
  const SSHCredentialsException([
    super.message = 'Could not read the saved credentials.',
    super.cause,
  ]);
}
