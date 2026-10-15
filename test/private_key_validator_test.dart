import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/services/private_key_validator.dart';
import 'package:ssh_app/services/vault_exception.dart';

void main() {
  String fixture(String name) {
    return File('test/fixtures/$name').readAsStringSync();
  }

  test('accepts RSA, Ed25519, and ECDSA keys', () async {
    await validatePrivateKeyMaterial(fixture('id_ed25519'), null);
    await validatePrivateKeyMaterial(fixture('id_rsa_openssh'), null);
    await validatePrivateKeyMaterial(fixture('id_rsa_pem'), null);
    await validatePrivateKeyMaterial(fixture('id_ecdsa'), null);
    await validatePrivateKeyMaterial(
      fixture('id_ed25519_encrypted'),
      'correct-horse',
    );
  });

  test('rejects empty, garbage, and a wrong passphrase', () async {
    expect(
      () => validatePrivateKeyMaterial('   ', null),
      throwsA(
        isA<PrivateKeyValidationException>().having(
          (error) => error.field,
          'field',
          'privateKey',
        ),
      ),
    );
    expect(
      () => validatePrivateKeyMaterial('not a key', null),
      throwsA(
        isA<PrivateKeyValidationException>().having(
          (error) => error.message,
          'message',
          'This is not a valid OpenSSH or PEM private key.',
        ),
      ),
    );

    final encrypted = fixture('id_ed25519_encrypted');
    expect(
      () => validatePrivateKeyMaterial(encrypted, null),
      throwsA(
        isA<PrivateKeyValidationException>().having(
          (error) => error.field,
          'field',
          'passphrase',
        ),
      ),
    );
    expect(
      () => validatePrivateKeyMaterial(encrypted, 'nope'),
      throwsA(
        isA<PrivateKeyValidationException>().having(
          (error) => error.message,
          'message',
          'Could not decrypt the private key. Check the passphrase.',
        ),
      ),
    );
  });
}
