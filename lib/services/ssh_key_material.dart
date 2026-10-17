import 'dart:convert';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:pinenacl/ed25519.dart' as ed25519;
import 'package:pointycastle/export.dart' as pc;

enum KeyAlgorithm {
  ed25519('Ed25519'),
  rsa4096('RSA 4096');

  const KeyAlgorithm(this.label);

  final String label;
}

/// What can be told about a private key without storing it.
class KeyInfo {
  const KeyInfo({
    required this.type,
    required this.publicKey,
    required this.fingerprint,
    required this.encrypted,
  });

  /// "Ed25519", "RSA 4096", "ECDSA".
  final String type;

  /// OpenSSH `authorized_keys` line.
  final String publicKey;

  /// `SHA256:...`.
  final String fingerprint;
  final bool encrypted;
}

/// A new key: the private key as an OpenSSH PEM, and its details.
class GeneratedKey {
  const GeneratedKey({required this.privateKey, required this.info});

  final String privateKey;
  final KeyInfo info;
}

/// `SHA256:` and the unpadded base64 of the SHA-256 of the public key blob,
/// the text `ssh-keygen -lf` prints.
String sshFingerprint(Uint8List publicKeyBlob) {
  final digest = pc.SHA256Digest().process(publicKeyBlob);
  return 'SHA256:${base64.encode(digest).replaceAll('=', '')}';
}

/// One `authorized_keys` line: `ssh-ed25519 AAAA... comment`.
String openSshPublicKeyLine(SSHKeyPair pair, String comment) {
  final blob = pair.toPublicKey().encode();
  final cleaned = comment.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
  return '${pair.name} ${base64.encode(blob)}${cleaned.isEmpty ? '' : ' $cleaned'}';
}

String _typeLabel(SSHKeyPair pair) {
  if (pair.name == 'ssh-ed25519') return 'Ed25519';
  if (pair.name.startsWith('ecdsa-')) return 'ECDSA';
  if (pair.name == 'ssh-rsa') {
    final blob = pair.toPublicKey().encode();
    // Bits of the modulus: read from the wire format (string, mpint e, mpint n).
    final bits = _rsaBits(blob);
    return bits == null ? 'RSA' : 'RSA $bits';
  }
  return pair.name;
}

/// Bits in the modulus of an `ssh-rsa` public key blob: a string with the
/// algorithm, then the mpints e and n, each with a 4-byte length prefix.
int? _rsaBits(Uint8List blob) {
  try {
    final data = ByteData.sublistView(blob);
    var offset = 0;
    Uint8List field() {
      final length = data.getUint32(offset);
      final start = offset + 4;
      offset = start + length;
      return Uint8List.sublistView(blob, start, offset);
    }

    field(); // algorithm name
    field(); // e
    final n = field();
    var i = 0;
    while (i < n.length && n[i] == 0) {
      i++;
    }
    if (i == n.length) return null;
    return (n.length - i - 1) * 8 + (8 - _leadingZeroBits(n[i]));
  } catch (_) {
    return null;
  }
}

int _leadingZeroBits(int byte) {
  var count = 0;
  for (var bit = 7; bit >= 0 && (byte >> bit) & 1 == 0; bit--) {
    count++;
  }
  return count;
}

/// Details of [privateKey]. Throws [FormatException] with a message safe to
/// show when it cannot be read, or when it is encrypted and [passphrase] is
/// missing or wrong. Encrypted OpenSSH keys use bcrypt, so run this through
/// [inspectPrivateKeyInBackground] from the UI.
KeyInfo inspectPrivateKey(
  String privateKey,
  String? passphrase, {
  String comment = '',
}) {
  final pem = privateKey.trim();
  final bool encrypted;
  try {
    encrypted = SSHKeyPair.isEncryptedPem(pem);
  } catch (_) {
    throw const FormatException(
      'This is not a valid OpenSSH or PEM private key.',
    );
  }
  if (encrypted && (passphrase == null || passphrase.isEmpty)) {
    throw const FormatException(
      'This private key is encrypted. Enter its passphrase.',
    );
  }
  final List<SSHKeyPair> pairs;
  try {
    pairs = SSHKeyPair.fromPem(pem, encrypted ? passphrase : null);
  } catch (_) {
    throw FormatException(
      encrypted
          ? 'Could not decrypt the private key. Check the passphrase.'
          : 'This is not a valid OpenSSH or PEM private key.',
    );
  }
  if (pairs.isEmpty) {
    throw const FormatException(
      'This is not a valid OpenSSH or PEM private key.',
    );
  }
  final pair = pairs.first;
  final type = _typeLabel(pair);
  if (!type.startsWith('RSA') && type != 'Ed25519' && type != 'ECDSA') {
    throw const FormatException(
      'Only RSA, Ed25519, and ECDSA private keys are supported.',
    );
  }
  return KeyInfo(
    type: type,
    publicKey: openSshPublicKeyLine(pair, comment),
    fingerprint: sshFingerprint(pair.toPublicKey().encode()),
    encrypted: encrypted,
  );
}

({String? error, String? type, String? publicKey, String? fingerprint, bool encrypted})
_inspectEntry((String, String?, String) args) {
  try {
    final info = inspectPrivateKey(args.$1, args.$2, comment: args.$3);
    return (
      error: null,
      type: info.type,
      publicKey: info.publicKey,
      fingerprint: info.fingerprint,
      encrypted: info.encrypted,
    );
  } on FormatException catch (e) {
    return (
      error: e.message,
      type: null,
      publicKey: null,
      fingerprint: null,
      encrypted: false,
    );
  }
}

/// [inspectPrivateKey] off the UI thread.
Future<KeyInfo> inspectPrivateKeyInBackground(
  String privateKey,
  String? passphrase, {
  String comment = '',
}) async {
  final result = await compute(_inspectEntry, (privateKey, passphrase, comment));
  final error = result.error;
  if (error != null) {
    throw FormatException(error);
  }
  return KeyInfo(
    type: result.type!,
    publicKey: result.publicKey!,
    fingerprint: result.fingerprint!,
    encrypted: result.encrypted,
  );
}

/// Makes a new key pair. [rsaBits] is only for tests; the app uses 4096.
GeneratedKey generateKey(
  KeyAlgorithm algorithm, {
  String? passphrase,
  String comment = '',
  int rsaBits = 4096,
}) {
  final SSHKeyPair pair;
  final String pem;
  final secret = passphrase == null || passphrase.isEmpty ? null : passphrase;
  switch (algorithm) {
    case KeyAlgorithm.ed25519:
      final signing = ed25519.SigningKey.generate();
      final key = OpenSSHEd25519KeyPair(
        Uint8List.fromList(signing.verifyKey.asTypedList),
        Uint8List.fromList(signing.asTypedList),
        comment,
      );
      pair = key;
      pem = key.toPem(passphrase: secret);
    case KeyAlgorithm.rsa4096:
      final generator = pc.RSAKeyGenerator()
        ..init(
          pc.ParametersWithRandom(
            pc.RSAKeyGeneratorParameters(BigInt.from(65537), rsaBits, 64),
            _secureRandom(),
          ),
        );
      final generated = generator.generateKeyPair();
      final private = generated.privateKey;
      final p = private.p!;
      final q = private.q!;
      final key = OpenSSHRsaKeyPair(
        private.modulus!,
        private.publicExponent!,
        private.privateExponent!,
        q.modInverse(p),
        p,
        q,
        comment,
      );
      pair = key;
      pem = key.toPem(passphrase: secret);
  }
  return GeneratedKey(
    privateKey: pem,
    info: KeyInfo(
      type: algorithm == KeyAlgorithm.ed25519
          ? 'Ed25519'
          : 'RSA $rsaBits',
      publicKey: openSshPublicKeyLine(pair, comment),
      fingerprint: sshFingerprint(pair.toPublicKey().encode()),
      encrypted: secret != null,
    ),
  );
}

pc.SecureRandom _secureRandom() {
  final random = Random.secure();
  final seed = Uint8List.fromList(
    List<int>.generate(32, (_) => random.nextInt(256)),
  );
  return pc.FortunaRandom()..seed(pc.KeyParameter(seed));
}

({String privateKey, String type, String publicKey, String fingerprint, bool encrypted})
_generateEntry((int, String?, String, int) args) {
  final key = generateKey(
    KeyAlgorithm.values[args.$1],
    passphrase: args.$2,
    comment: args.$3,
    rsaBits: args.$4,
  );
  return (
    privateKey: key.privateKey,
    type: key.info.type,
    publicKey: key.info.publicKey,
    fingerprint: key.info.fingerprint,
    encrypted: key.info.encrypted,
  );
}

/// [generateKey] in a background isolate. RSA 4096 can take a minute on a
/// phone, and encrypting with a passphrase runs bcrypt.
Future<GeneratedKey> generateKeyInBackground(
  KeyAlgorithm algorithm, {
  String? passphrase,
  String comment = '',
  int rsaBits = 4096,
}) async {
  final result = await compute(_generateEntry, (
    algorithm.index,
    passphrase,
    comment,
    rsaBits,
  ));
  return GeneratedKey(
    privateKey: result.privateKey,
    info: KeyInfo(
      type: result.type,
      publicKey: result.publicKey,
      fingerprint: result.fingerprint,
      encrypted: result.encrypted,
    ),
  );
}
