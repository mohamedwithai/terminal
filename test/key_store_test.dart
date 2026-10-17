import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/services/ssh_key_material.dart';
import 'package:ssh_app/services/vault_exception.dart';
import 'package:ssh_app/services/vault_service.dart';

import 'support/memory_stores.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  late MemorySecureStore secure;
  late MemoryMetadataStore metadata;
  late VaultService vault;

  ServerConfig server(
    String id, {
    AuthType auth = AuthType.privateKey,
    String? keyId,
  }) {
    return ServerConfig.create(
      id: id,
      label: 'Host $id',
      host: '$id.example.com',
      username: 'ada',
      authType: auth,
      now: DateTime.utc(2026, 5, 1),
    ).copyWith(keyId: keyId);
  }

  setUp(() {
    secure = MemorySecureStore();
    metadata = MemoryMetadataStore();
    vault = VaultService(
      secureStore: secure,
      metadataStore: metadata,
      clock: () => DateTime.utc(2026, 6, 1),
    );
  });

  Future<String> addGenerated(String name, {String? passphrase}) async {
    final key = generateKey(KeyAlgorithm.ed25519, passphrase: passphrase);
    final record = await vault.addKey(
      name: name,
      privateKey: key.privateKey,
      passphrase: passphrase,
      info: key.info,
    );
    return record.id;
  }

  test(
    'a saved key keeps its secret in secure storage, not in metadata',
    () async {
      final key = generateKey(KeyAlgorithm.ed25519, passphrase: 'pw');
      final record = await vault.addKey(
        name: ' Laptop ',
        privateKey: key.privateKey,
        passphrase: 'pw',
        info: key.info,
      );

      expect(record.name, 'Laptop');
      expect(record.encrypted, isTrue);
      expect(
        metadata.keys.values.single,
        isNot(contains('OPENSSH PRIVATE KEY')),
      );
      expect(metadata.keys.values.single, isNot(contains('pw')));
      final stored =
          jsonDecode(secure.values[keyStorageKey(record.id)]!) as Map;
      expect(stored['privateKey'], key.privateKey);
      expect(stored['passphrase'], 'pw');
      expect((await vault.listKeys()).single, record);
    },
  );

  test('the same key cannot be saved twice', () async {
    final key = generateKey(KeyAlgorithm.ed25519);
    await vault.addKey(name: 'One', privateKey: key.privateKey, info: key.info);

    expect(
      () =>
          vault.addKey(name: 'Two', privateKey: key.privateKey, info: key.info),
      throwsA(
        isA<VaultException>().having(
          (e) => e.message,
          'message',
          contains('"One"'),
        ),
      ),
    );
    expect(await vault.listKeys(), hasLength(1));
  });

  test('an empty name is a validation error and writes nothing', () async {
    final key = generateKey(KeyAlgorithm.ed25519);
    await expectLater(
      vault.addKey(name: '  ', privateKey: key.privateKey, info: key.info),
      throwsA(isA<VaultValidationException>()),
    );
    expect(secure.values, isEmpty);
    expect(metadata.keys, isEmpty);
  });

  test('a failing secure store saves nothing', () async {
    final failing = VaultService(
      secureStore: FailingSecureStore(),
      metadataStore: metadata,
    );
    final key = generateKey(KeyAlgorithm.ed25519);
    await expectLater(
      failing.addKey(name: 'K', privateKey: key.privateKey, info: key.info),
      throwsA(isA<VaultException>()),
    );
    expect(metadata.keys, isEmpty);
  });

  test('a server with a saved key signs in with that key', () async {
    final keyId = await addGenerated('Phone key', passphrase: 'pw');
    await vault.saveServer(
      server('a', keyId: keyId),
      const ServerCredentials(),
    );

    final credentials = (await vault.readCredentials('a'))!;
    final material = await vault.readKeyMaterial(keyId);
    expect(credentials, material);
    expect(credentials.passphrase, 'pw');
    // The edit form sees no private key of its own.
    expect((await vault.readOwnCredentials('a'))?.privateKey, isNull);
  });

  test('a server cannot point at a key that does not exist', () async {
    await expectLater(
      vault.saveServer(server('a', keyId: 'gone'), const ServerCredentials()),
      throwsA(
        isA<VaultValidationException>().having(
          (e) => e.fieldErrors.keys,
          'fields',
          contains('keyId'),
        ),
      ),
    );
    expect(metadata.servers, isEmpty);
  });

  test('switching a host to a password drops its key', () async {
    final keyId = await addGenerated('K');
    await vault.saveServer(
      server('a', keyId: keyId),
      const ServerCredentials(),
    );
    await vault.saveServer(
      server('a', auth: AuthType.password, keyId: keyId),
      const ServerCredentials(password: 'pw'),
    );

    expect((await vault.getServer('a'))!.keyId, isNull);
    expect((await vault.readCredentials('a'))!.password, 'pw');
    // Not used any more, so it can be deleted.
    await vault.deleteKey(keyId);
  });

  test('a key in use cannot be deleted; an unused one can', () async {
    final used = await addGenerated('Used');
    final spare = await addGenerated('Spare');
    await vault.saveServer(server('a', keyId: used), const ServerCredentials());
    await vault.saveServer(server('b', keyId: used), const ServerCredentials());

    await expectLater(
      vault.deleteKey(used),
      throwsA(
        isA<VaultException>().having(
          (e) => e.message,
          'message',
          contains('2 hosts'),
        ),
      ),
    );
    expect(secure.values.containsKey(keyStorageKey(used)), isTrue);

    await vault.deleteKey(spare);
    expect(secure.values.containsKey(keyStorageKey(spare)), isFalse);
    expect((await vault.listKeys()).map((k) => k.id), [used]);
  });

  test('a missing key gives a message that says what to do', () async {
    final keyId = await addGenerated('K');
    await vault.saveServer(
      server('a', keyId: keyId),
      const ServerCredentials(),
    );
    secure.values.remove(keyStorageKey(keyId));

    await expectLater(
      vault.readCredentials('a'),
      throwsA(
        isA<VaultException>().having(
          (e) => e.message,
          'message',
          contains('Pick another key'),
        ),
      ),
    );
  });

  test('renaming changes only the name', () async {
    final id = await addGenerated('Old');
    final renamed = await vault.renameKey(id, 'New');

    expect(renamed.name, 'New');
    expect((await vault.getKey(id))!.fingerprint, renamed.fingerprint);
    await expectLater(
      vault.renameKey(id, ''),
      throwsA(isA<VaultValidationException>()),
    );
  });

  group('migration', () {
    Future<void> pasted(String id, String pem, {String? passphrase}) {
      return vault.saveServer(
        server(id),
        ServerCredentials(privateKey: pem, passphrase: passphrase),
      );
    }

    test('pasted keys move into the key store; the same key becomes one', () async {
      await pasted('a', fixture('id_ed25519'));
      await pasted('b', fixture('id_ed25519'));
      await pasted('c', fixture('id_rsa_openssh'));
      await vault.saveServer(
        server('p', auth: AuthType.password),
        const ServerCredentials(password: 'pw'),
      );

      expect(await vault.migratePastedKeys(), 3);

      final keys = await vault.listKeys();
      expect(keys, hasLength(2));
      expect(
        keys.map((k) => k.name),
        containsAll(['Host a key', 'Host c key']),
      );
      final a = (await vault.getServer('a'))!;
      expect(a.keyId, (await vault.getServer('b'))!.keyId);
      expect(a.keyId, isNot((await vault.getServer('c'))!.keyId));
      expect((await vault.getServer('p'))!.keyId, isNull);

      // Signing in works as before, and the host no longer holds its own copy.
      expect(
        (await vault.readCredentials('a'))!.privateKey,
        fixture('id_ed25519').trim(),
      );
      expect(jsonDecode(secure.values[credentialStorageKey('a')]!), isEmpty);
      // Passwords are untouched.
      expect((await vault.readCredentials('p'))!.password, 'pw');
    });

    test('an encrypted key keeps its passphrase', () async {
      final key = generateKey(KeyAlgorithm.ed25519, passphrase: 'pw');
      await pasted('a', key.privateKey, passphrase: 'pw');

      expect(await vault.migratePastedKeys(), 1);

      final credentials = (await vault.readCredentials('a'))!;
      expect(credentials.passphrase, 'pw');
      expect((await vault.listKeys()).single.encrypted, isTrue);
    });

    test('running it again changes nothing', () async {
      await pasted('a', fixture('id_ed25519'));
      await vault.migratePastedKeys();

      expect(await vault.migratePastedKeys(), 0);
      expect(await vault.listKeys(), hasLength(1));
    });

    test('a key that cannot be read stays where it was', () async {
      await vault.saveServer(
        server('a'),
        ServerCredentials(privateKey: fixture('id_ed25519')),
      );
      // Corrupt it after saving, as an older version might have stored it.
      secure.values[credentialStorageKey('a')] = jsonEncode({
        'privateKey': 'not a key',
      });

      expect(await vault.migratePastedKeys(), 0);
      expect(await vault.listKeys(), isEmpty);
      expect((await vault.readCredentials('a'))!.privateKey, 'not a key');
    });

    test('a key name is made unique', () async {
      await addGenerated('Host a key');
      await pasted('a', fixture('id_ed25519'));
      await vault.migratePastedKeys();

      expect(
        (await vault.listKeys()).map((k) => k.name),
        contains('Host a key 2'),
      );
    });

    test('a failure while saving the key leaves the host as it was', () async {
      await pasted('a', fixture('id_ed25519'));
      final failing = VaultService(
        secureStore: _FailsOnKeyWrite(secure),
        metadataStore: metadata,
      );

      await expectLater(
        failing.migratePastedKeys(),
        throwsA(isA<VaultException>()),
      );

      expect((await vault.getServer('a'))!.keyId, isNull);
      expect(
        (await vault.readCredentials('a'))!.privateKey,
        fixture('id_ed25519').trim(),
      );
      expect(await vault.listKeys(), isEmpty);
    });
  });
}

/// Fails writes of key secrets and passes everything else to [inner].
class _FailsOnKeyWrite extends MemorySecureStore {
  _FailsOnKeyWrite(MemorySecureStore inner) {
    values.addAll(inner.values);
  }

  @override
  Future<void> write(String key, String value) {
    if (key.startsWith('key_')) {
      throw StateError('disk full');
    }
    return super.write(key, value);
  }
}
