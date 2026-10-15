import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:ssh_app/services/vault_exception.dart';

const _invalidKeyMessage =
    'This is not a valid OpenSSH or PEM private key.';

/// Top-level so [compute] can run it in a background isolate.
///
/// Encrypted OpenSSH keys use bcrypt and will stall the UI if parsed on
/// the platform thread. The return value is a record so it can cross the
/// isolate boundary.
({String? field, String? message}) checkPrivateKey((String, String?) args) {
  final pem = args.$1.trim();
  final passphrase = args.$2;
  if (pem.isEmpty) {
    return (
      field: 'privateKey',
      message: 'Paste an OpenSSH or PEM private key.',
    );
  }

  final encrypted = _encryptionFlag(pem);
  if (encrypted == null) {
    return (field: 'privateKey', message: _invalidKeyMessage);
  }
  if (encrypted && (passphrase == null || passphrase.isEmpty)) {
    return (
      field: 'passphrase',
      message: 'This private key is encrypted. Enter its passphrase.',
    );
  }

  try {
    final keys = SSHKeyPair.fromPem(pem, encrypted ? passphrase : null);
    if (keys.isEmpty) {
      return (field: 'privateKey', message: _invalidKeyMessage);
    }
    final name = keys.first.name;
    if (name != 'ssh-rsa' &&
        name != 'ssh-ed25519' &&
        !name.startsWith('ecdsa-')) {
      return (
        field: 'privateKey',
        message: 'Only RSA, Ed25519, and ECDSA private keys are supported.',
      );
    }
    return (field: null, message: null);
  } catch (_) {
    if (encrypted) {
      return (
        field: 'passphrase',
        message: 'Could not decrypt the private key. Check the passphrase.',
      );
    }
    return (field: 'privateKey', message: _invalidKeyMessage);
  }
}

/// Parses [privateKey] with dartssh2.
///
/// Throws [PrivateKeyValidationException] with a message safe to show in
/// the form. The exception never includes key material.
Future<void> validatePrivateKeyMaterial(
  String privateKey,
  String? passphrase,
) async {
  final pem = privateKey.trim();
  final encrypted = pem.isEmpty ? false : _encryptionFlag(pem);
  final ({String? field, String? message}) outcome;
  if (encrypted == true) {
    outcome = await compute(checkPrivateKey, (pem, passphrase));
  } else {
    outcome = checkPrivateKey((pem, passphrase));
  }
  final field = outcome.field;
  final message = outcome.message;
  if (field != null && message != null) {
    throw PrivateKeyValidationException(field, message);
  }
}

/// True when the PEM is encrypted, false when it is not, null when it is
/// not a PEM this parser understands.
bool? _encryptionFlag(String pem) {
  try {
    return SSHKeyPair.isEncryptedPem(pem);
  } on FormatException {
    return null;
  } on UnsupportedError {
    return null;
  }
}
