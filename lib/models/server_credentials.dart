/// Secrets for one server. Stored only in the platform secure store.
class ServerCredentials {
  const ServerCredentials({
    this.password,
    this.privateKey,
    this.passphrase,
  });

  factory ServerCredentials.fromJson(Map<String, dynamic> json) {
    return ServerCredentials(
      password: _optionalString(json['password']),
      privateKey: _optionalString(json['privateKey']),
      passphrase: _optionalString(json['passphrase']),
    );
  }

  final String? password;

  /// OpenSSH or PEM private key text.
  final String? privateKey;

  /// Passphrase for an encrypted private key. Null when the key is not encrypted.
  final String? passphrase;

  static const Object _unset = Object();

  ServerCredentials copyWith({
    Object? password = _unset,
    Object? privateKey = _unset,
    Object? passphrase = _unset,
  }) {
    return ServerCredentials(
      password: identical(password, _unset) ? this.password : password as String?,
      privateKey:
          identical(privateKey, _unset) ? this.privateKey : privateKey as String?,
      passphrase:
          identical(passphrase, _unset) ? this.passphrase : passphrase as String?,
    );
  }

  /// Omits null fields so a password record does not keep an old private key.
  Map<String, dynamic> toJson() {
    return {
      if (password != null) 'password': password,
      if (privateKey != null) 'privateKey': privateKey,
      if (passphrase != null) 'passphrase': passphrase,
    };
  }

  @override
  bool operator ==(Object other) {
    return other is ServerCredentials &&
        other.password == password &&
        other.privateKey == privateKey &&
        other.passphrase == passphrase;
  }

  @override
  int get hashCode => Object.hash(password, privateKey, passphrase);

  /// Debug text without secret material.
  @override
  String toString() {
    return 'ServerCredentials('
        'hasPassword: ${password != null}, '
        'hasPrivateKey: ${privateKey != null}, '
        'hasPassphrase: ${passphrase != null})';
  }
}

String? _optionalString(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw const FormatException('Credential field must be a string.');
  }
  return value.isEmpty ? null : value;
}
