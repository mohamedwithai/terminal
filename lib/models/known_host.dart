/// A host key the user has accepted for later trust-on-first-use checks.
///
/// Phase 2 compares a server's presented key with [fingerprint]. The
/// fingerprint is the OpenSSH SHA-256 form, for example `SHA256:abcd...`.
class KnownHost {
  const KnownHost({
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprint,
    required this.addedAt,
  });

  factory KnownHost.fromJson(Map<String, dynamic> json) {
    final host = json['host'];
    final keyType = json['keyType'];
    final fingerprint = json['fingerprint'];
    final addedAt = json['addedAt'];
    final port = json['port'];
    if (host is! String ||
        keyType is! String ||
        fingerprint is! String ||
        addedAt is! String ||
        port is! num) {
      throw const FormatException('Known host record is incomplete.');
    }
    return KnownHost(
      host: host,
      port: port.toInt(),
      keyType: keyType,
      fingerprint: fingerprint,
      addedAt: DateTime.parse(addedAt).toUtc(),
    );
  }

  final String host;
  final int port;

  /// Algorithm name reported by the server, such as `ssh-ed25519`.
  final String keyType;

  /// SHA-256 fingerprint of the host key.
  final String fingerprint;
  final DateTime addedAt;

  Map<String, String> get fieldErrors {
    final errors = <String, String>{};
    if (host.trim().isEmpty) {
      errors['host'] = 'Enter a hostname or IP address.';
    }
    if (port < 1 || port > 65535) {
      errors['port'] = 'Enter a port from 1 to 65535.';
    }
    if (keyType.trim().isEmpty) {
      errors['keyType'] = 'Missing host key type.';
    }
    if (fingerprint.trim().isEmpty) {
      errors['fingerprint'] = 'Missing SHA-256 fingerprint.';
    }
    return errors;
  }

  KnownHost copyWith({
    String? host,
    int? port,
    String? keyType,
    String? fingerprint,
    DateTime? addedAt,
  }) {
    return KnownHost(
      host: host ?? this.host,
      port: port ?? this.port,
      keyType: keyType ?? this.keyType,
      fingerprint: fingerprint ?? this.fingerprint,
      addedAt: addedAt ?? this.addedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'host': host,
      'port': port,
      'keyType': keyType,
      'fingerprint': fingerprint,
      'addedAt': addedAt.toUtc().toIso8601String(),
    };
  }

  @override
  bool operator ==(Object other) {
    return other is KnownHost &&
        other.host == host &&
        other.port == port &&
        other.keyType == keyType &&
        other.fingerprint == fingerprint &&
        other.addedAt.toUtc() == addedAt.toUtc();
  }

  @override
  int get hashCode =>
      Object.hash(host, port, keyType, fingerprint, addedAt.toUtc());

  @override
  String toString() {
    return 'KnownHost(host: $host, port: $port, keyType: $keyType, '
        'fingerprint: $fingerprint)';
  }
}
