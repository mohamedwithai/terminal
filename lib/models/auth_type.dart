/// How an SSH session authenticates.
///
/// The stored name is the enum identifier. Do not rename a value without a
/// migration; Hive records keep this string.
enum AuthType {
  /// Username and a password held in the secure store.
  password,

  /// Username and an RSA or Ed25519 private key held in the secure store.
  privateKey;

  /// Label shown on the server list and the add/edit form.
  String get label => switch (this) {
        AuthType.password => 'Password',
        AuthType.privateKey => 'Private key',
      };

  /// Reads a value previously written by [Enum.name].
  static AuthType parse(String value) {
    for (final type in AuthType.values) {
      if (type.name == value) {
        return type;
      }
    }
    throw FormatException('Unknown auth type "$value".');
  }
}
