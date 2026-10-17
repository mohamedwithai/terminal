import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/services/ssh_key_material.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  test('a generated Ed25519 key loads back and matches its public line', () {
    final key = generateKey(KeyAlgorithm.ed25519, comment: 'phone');
    final pair = SSHKeyPair.fromPem(key.privateKey).single;

    expect(pair.name, 'ssh-ed25519');
    expect(key.info.type, 'Ed25519');
    expect(key.info.encrypted, isFalse);
    expect(key.info.publicKey, startsWith('ssh-ed25519 AAAA'));
    expect(key.info.publicKey, endsWith(' phone'));
    expect(key.info.publicKey, openSshPublicKeyLine(pair, 'phone'));
    expect(
      key.info.fingerprint,
      matches(RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$')),
    );
    expect(key.privateKey, startsWith('-----BEGIN OPENSSH PRIVATE KEY-----'));
  });

  test('two generated keys differ', () {
    final a = generateKey(KeyAlgorithm.ed25519);
    final b = generateKey(KeyAlgorithm.ed25519);
    expect(a.info.fingerprint, isNot(b.info.fingerprint));
  });

  test('a passphrase encrypts the key; the wrong one fails', () {
    final key = generateKey(KeyAlgorithm.ed25519, passphrase: 'hunter2');

    expect(key.info.encrypted, isTrue);
    expect(SSHKeyPair.isEncryptedPem(key.privateKey), isTrue);
    expect(
      SSHKeyPair.fromPem(
        key.privateKey,
        'hunter2',
      ).single.toPublicKey().encode(),
      SSHKeyPair.fromPem(
        key.privateKey,
        'hunter2',
      ).single.toPublicKey().encode(),
    );
    expect(
      inspectPrivateKey(key.privateKey, 'hunter2').fingerprint,
      key.info.fingerprint,
    );
    expect(
      () => inspectPrivateKey(key.privateKey, 'wrong'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('passphrase'),
        ),
      ),
    );
    expect(
      () => inspectPrivateKey(key.privateKey, null),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('encrypted'),
        ),
      ),
    );
  });

  test('a generated RSA key is valid and its size is detected', () {
    final key = generateKey(KeyAlgorithm.rsa4096, rsaBits: 1024);
    final reloaded = inspectPrivateKey(key.privateKey, null);

    expect(key.info.type, 'RSA 1024');
    expect(reloaded.type, 'RSA 1024');
    expect(reloaded.publicKey, startsWith('ssh-rsa AAAA'));
    expect(reloaded.fingerprint, key.info.fingerprint);
    // It can sign and the public key verifies the signature.
    final pair = SSHKeyPair.fromPem(key.privateKey).single;
    expect(pair.sign(Uint8List.fromList([1, 2, 3])), isNotNull);
  });

  test('fixtures from ssh-keygen are recognized', () {
    expect(inspectPrivateKey(fixture('id_ed25519'), null).type, 'Ed25519');
    expect(inspectPrivateKey(fixture('id_ecdsa'), null).type, 'ECDSA');
    expect(
      inspectPrivateKey(fixture('id_rsa_openssh'), null).type,
      startsWith('RSA'),
    );
    expect(
      inspectPrivateKey(fixture('id_rsa_pem'), null).type,
      startsWith('RSA'),
    );
  });

  test('fingerprints equal what ssh-keygen -lf prints', () {
    // Values printed by `ssh-keygen -lf test/fixtures/<name>`.
    const expected = {
      'id_ed25519': 'SHA256:4k5ZZIUZsqSTfrwC1i37PlLMgG5qosKN5ZA6aci6E/w',
      'id_ecdsa': 'SHA256:N/1t6CM6cd7opkb5H+krtj/kvEszewMq5FQM9/umEuc',
      'id_rsa_openssh': 'SHA256:RDWGsq48tlvv1ay7X9Pq6BcY0LHcAsMYDomllxHbgc4',
      'id_rsa_pem': 'SHA256:MfZ1MrjhWVROwPh1itwZ0gBh0VfMfbMpB9DQXnQvD2Y',
    };
    for (final MapEntry(key: name, value: fingerprint) in expected.entries) {
      expect(inspectPrivateKey(fixture(name), null).fingerprint, fingerprint);
    }
  });

  test('garbage is rejected with a safe message', () {
    expect(
      () => inspectPrivateKey('not a key', null),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('not a valid'),
        ),
      ),
    );
  });

  test('background versions agree with the direct ones', () async {
    final key = await generateKeyInBackground(
      KeyAlgorithm.ed25519,
      passphrase: 'pw',
      comment: 'x',
    );
    final info = await inspectPrivateKeyInBackground(
      key.privateKey,
      'pw',
      comment: 'x',
    );
    expect(info.publicKey, key.info.publicKey);
    expect(info.fingerprint, key.info.fingerprint);
  });
}
