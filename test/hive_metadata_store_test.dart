import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/known_host.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/services/hive_metadata_store.dart';
import 'package:ssh_app/services/vault_service.dart';

import 'support/memory_stores.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ssh_hive_');
    Hive.init(directory.path);
  });

  tearDown(() async {
    await Hive.close();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  test('hive stores server metadata and known hosts, not secrets', () async {
    final metadata = await HiveMetadataStore.open();
    final secure = MemorySecureStore();
    final vault = VaultService(
      secureStore: secure,
      metadataStore: metadata,
      clock: () => DateTime.utc(2026, 4, 1),
    );
    final server = ServerConfig.create(
      id: 'hive-1',
      label: 'Hive host',
      host: 'db.internal',
      username: 'ops',
      authType: AuthType.password,
      now: DateTime.utc(2026, 4, 1),
    );

    await vault.saveServer(
      server,
      const ServerCredentials(password: 'hive-secret'),
    );
    await vault.saveKnownHost(
      KnownHost(
        host: 'db.internal',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:hive',
        addedAt: DateTime.utc(2026, 4, 1),
      ),
    );

    final box = Hive.box<String>(HiveMetadataStore.serversBoxName);
    final raw = box.get('hive-1');
    expect(raw, isNotNull);
    expect(raw, isNot(contains('hive-secret')));
    expect((await vault.listServers()).single.label, 'Hive host');
    expect((await vault.listKnownHosts()).single.fingerprint, 'SHA256:hive');

    await vault.deleteServer('hive-1');
    expect(box.get('hive-1'), isNull);
    expect(secure.values, isEmpty);
    await metadata.close();
  });
}
