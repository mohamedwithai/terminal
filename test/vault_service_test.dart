import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/known_host.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/services/vault_exception.dart';
import 'package:ssh_app/services/vault_service.dart';

import 'support/memory_stores.dart';

void main() {
  late MemorySecureStore secure;
  late MemoryMetadataStore metadata;
  late DateTime now;
  late VaultService vault;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    secure = MemorySecureStore();
    metadata = MemoryMetadataStore();
    now = DateTime.utc(2026, 3, 1, 12);
    vault = VaultService(
      secureStore: secure,
      metadataStore: metadata,
      clock: () => now,
    );
  });

  ServerConfig config({
    String id = 'server-1',
    AuthType authType = AuthType.password,
    String label = 'Build box',
  }) {
    return ServerConfig.create(
      id: id,
      label: label,
      host: 'example.com',
      username: 'ada',
      authType: authType,
      now: DateTime.utc(2020),
    );
  }

  test('password credentials are stored only under cred_<id>', () async {
    final server = config();
    final stored = await vault.saveServer(
      server,
      const ServerCredentials(password: 's3cret-password'),
    );

    expect(stored.createdAt, now);
    expect(stored.updatedAt, now);
    expect(secure.values.keys, ['cred_server-1']);
    expect(secure.values['cred_server-1'], contains('s3cret-password'));
    expect(metadata.servers['server-1'], isNot(contains('s3cret-password')));

    final read = await vault.readCredentials('server-1');
    expect(read?.password, 's3cret-password');
    expect(read?.privateKey, isNull);
  });

  test('update keeps createdAt and replaces the secret', () async {
    final server = config();
    await vault.saveServer(
      server,
      const ServerCredentials(password: 'first'),
    );
    now = now.add(const Duration(hours: 2));
    final updated = await vault.saveServer(
      server.copyWith(label: 'Renamed'),
      const ServerCredentials(password: 'second'),
    );

    expect(updated.createdAt, DateTime.utc(2026, 3, 1, 12));
    expect(updated.updatedAt, now);
    expect(updated.label, 'Renamed');
    expect((await vault.readCredentials('server-1'))?.password, 'second');
    expect(secure.values['cred_server-1'], isNot(contains('first')));
  });

  test('delete removes metadata and the credential', () async {
    await vault.saveServer(
      config(),
      const ServerCredentials(password: 's3cret-password'),
    );

    await vault.deleteServer('server-1');

    expect(await vault.getServer('server-1'), isNull);
    expect(await vault.readCredentials('server-1'), isNull);
    expect(secure.values, isEmpty);
    expect(metadata.servers, isEmpty);
  });

  test('invalid password auth writes nothing', () async {
    expect(
      () => vault.saveServer(config(), const ServerCredentials()),
      throwsA(isA<VaultValidationException>()),
    );
    expect(secure.values, isEmpty);
    expect(metadata.servers, isEmpty);
  });

  test('a secure-store failure becomes a VaultException and writes nothing',
      () async {
    final failing = VaultService(
      secureStore: FailingSecureStore(),
      metadataStore: metadata,
    );

    await expectLater(
      failing.saveServer(config(), const ServerCredentials(password: 'pw')),
      throwsA(
        isA<VaultException>().having(
          (error) => error.message,
          'message',
          startsWith('Could not save the credentials to secure storage.'),
        ),
      ),
    );
    expect(metadata.servers, isEmpty);
  });

  test('OpenSSH Ed25519, OpenSSH RSA, and PEM RSA keys round-trip', () async {
    for (final fixture in ['id_ed25519', 'id_rsa_openssh', 'id_rsa_pem']) {
      final pem = File('test/fixtures/$fixture').readAsStringSync();
      final id = 'id-$fixture';
      await vault.saveServer(
        config(id: id, authType: AuthType.privateKey),
        ServerCredentials(privateKey: pem, passphrase: 'ignored'),
      );

      final stored = ServerCredentials.fromJson(
        Map<String, dynamic>.from(
          (await vault.readCredentials(id))!.toJson(),
        ),
      );
      expect(stored.privateKey, pem.trim());
      expect(stored.passphrase, isNull);
      expect(stored.password, isNull);
      expect(metadata.servers[id], isNot(contains('OPENSSH')));
      expect(metadata.servers[id], isNot(contains('PRIVATE KEY')));
    }
  });

  test('encrypted Ed25519 key keeps its passphrase', () async {
    final pem = File('test/fixtures/id_ed25519_encrypted').readAsStringSync();
    await vault.saveServer(
      config(authType: AuthType.privateKey),
      ServerCredentials(privateKey: pem, passphrase: 'correct-horse'),
    );

    final stored = await vault.readCredentials('server-1');
    expect(stored?.passphrase, 'correct-horse');
    expect(stored?.privateKey, pem.trim());
  });

  test('a bad private key or passphrase writes nothing', () async {
    final encrypted =
        File('test/fixtures/id_ed25519_encrypted').readAsStringSync();
    final ecdsa = File('test/fixtures/id_ecdsa').readAsStringSync();

    Future<void> expectRejected(ServerCredentials credentials) async {
      await expectLater(
        vault.saveServer(config(authType: AuthType.privateKey), credentials),
        throwsA(isA<VaultValidationException>()),
      );
      expect(secure.values, isEmpty);
      expect(metadata.servers, isEmpty);
    }

    await expectRejected(const ServerCredentials(privateKey: 'not a key'));
    await expectRejected(
      ServerCredentials(privateKey: encrypted, passphrase: 'wrong'),
    );
    await expectRejected(ServerCredentials(privateKey: encrypted));
    await expectRejected(
      const ServerCredentials(privateKey: '-----BEGIN DSA PRIVATE KEY-----\nbad'),
    );

    // ECDSA is now supported in Phase 2
    final savedEcdsa = await vault.saveServer(
      config(authType: AuthType.privateKey),
      ServerCredentials(privateKey: ecdsa),
    );
    expect(savedEcdsa.id, 'server-1');
  });

  test('known hosts replace the same host and port', () async {
    final first = KnownHost(
      host: 'example.com',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:one',
      addedAt: now,
    );
    final second = first.copyWith(fingerprint: 'SHA256:two');
    await vault.saveKnownHost(first);
    await vault.saveKnownHost(second);

    final hosts = await vault.listKnownHosts();
    expect(hosts, [second]);
    await vault.deleteKnownHost('example.com', 22);
    expect(await vault.listKnownHosts(), isEmpty);
  });
}
