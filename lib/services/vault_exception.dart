/// Failure while reading or writing the local vault.
class VaultException implements Exception {
  VaultException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The add/edit form rejected a server before anything was written.
class VaultValidationException extends VaultException {
  VaultValidationException(this.fieldErrors)
    : super('Some server details are invalid.');

  /// Form field name to a message the user can act on.
  final Map<String, String> fieldErrors;
}

/// A private key could not be parsed or is not an accepted algorithm.
class PrivateKeyValidationException implements Exception {
  PrivateKeyValidationException(this.field, this.message);

  /// Either `privateKey` or `passphrase`.
  final String field;
  final String message;

  @override
  String toString() => message;
}
