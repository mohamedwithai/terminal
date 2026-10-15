import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/services/flutter_secure_store.dart';
import 'package:ssh_app/services/hive_metadata_store.dart';
import 'package:ssh_app/services/vault_service.dart';
import 'package:uuid/uuid.dart';

/// Runs on a device or emulator so [FlutterSecureStore] uses the real
/// Keystore or Keychain instead of the in-memory test double.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('writes, reads, and deletes a credential', (tester) async {
    await Hive.initFlutter();
    final metadata = await HiveMetadataStore.open();
    final secure = FlutterSecureStore();
    final vault = VaultService(
      secureStore: secure,
      metadataStore: metadata,
    );
    final id = const Uuid().v4();
    const password = 'phase1-test-password';

    try {
      final server = ServerConfig.create(
        id: id,
        label: 'Integration',
        host: '127.0.0.1',
        username: 'tester',
        authType: AuthType.password,
      );
      await vault.saveServer(server, const ServerCredentials(password: password));

      expect((await vault.readCredentials(id))?.password, password);
      final raw = await secure.read(credentialStorageKey(id));
      expect(raw, contains(password));

      await vault.deleteServer(id);

      expect(await vault.readCredentials(id), isNull);
      expect(await secure.read(credentialStorageKey(id)), isNull);
      expect(await vault.getServer(id), isNull);
    } finally {
      await vault.deleteServer(id);
      await metadata.close();
    }
  });
}
