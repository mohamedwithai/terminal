/// A saved SSH key's public details. The private key and its passphrase live
/// in secure storage under `key_<id>`, never here.
class SshKeyRecord {
  const SshKeyRecord({
    required this.id,
    required this.name,
    required this.type,
    required this.publicKey,
    required this.fingerprint,
    required this.encrypted,
    required this.createdAt,
  });

  factory SshKeyRecord.fromJson(Map<String, dynamic> json) {
    String text(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw FormatException('Key record is missing "$key".');
      }
      return value;
    }

    return SshKeyRecord(
      id: text('id'),
      name: text('name'),
      type: text('type'),
      publicKey: text('publicKey'),
      fingerprint: text('fingerprint'),
      encrypted: json['encrypted'] == true,
      createdAt: DateTime.parse(text('createdAt')).toUtc(),
    );
  }

  final String id;
  final String name;

  /// For display: "Ed25519", "RSA 4096", "ECDSA".
  final String type;

  /// One line in OpenSSH `authorized_keys` format.
  final String publicKey;

  /// `SHA256:...`, as `ssh-keygen -lf` prints it.
  final String fingerprint;

  /// The private key is protected by a passphrase.
  final bool encrypted;
  final DateTime createdAt;

  SshKeyRecord copyWith({String? name}) {
    return SshKeyRecord(
      id: id,
      name: name ?? this.name,
      type: type,
      publicKey: publicKey,
      fingerprint: fingerprint,
      encrypted: encrypted,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type,
    'publicKey': publicKey,
    'fingerprint': fingerprint,
    'encrypted': encrypted,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      other is SshKeyRecord &&
      other.id == id &&
      other.name == name &&
      other.type == type &&
      other.publicKey == publicKey &&
      other.fingerprint == fingerprint &&
      other.encrypted == encrypted &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(id, name, type, publicKey, fingerprint);

  @override
  String toString() => 'SshKeyRecord($id, $name, $type, $fingerprint)';
}
