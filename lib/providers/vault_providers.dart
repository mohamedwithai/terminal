import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/known_host.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/services/flutter_secure_store.dart';
import 'package:ssh_app/services/metadata_store.dart';
import 'package:ssh_app/services/secure_store.dart';
import 'package:ssh_app/services/vault_service.dart';

/// Opened in `main` with [HiveMetadataStore]. Tests override this.
final metadataStoreProvider = Provider<MetadataStore>((ref) {
  throw StateError('metadataStoreProvider must be overridden at startup.');
});

final secureStoreProvider = Provider<SecureStore>((ref) {
  return FlutterSecureStore();
});

final vaultServiceProvider = Provider<VaultService>((ref) {
  return VaultService(
    secureStore: ref.watch(secureStoreProvider),
    metadataStore: ref.watch(metadataStoreProvider),
  );
});

/// Saved servers, without their credentials.
final serverListProvider =
    AsyncNotifierProvider<ServerListNotifier, List<ServerConfig>>(
  ServerListNotifier.new,
);

class ServerListNotifier extends AsyncNotifier<List<ServerConfig>> {
  @override
  Future<List<ServerConfig>> build() {
    return ref.watch(vaultServiceProvider).listServers();
  }

  Future<void> save(ServerConfig config, ServerCredentials credentials) async {
    await ref.read(vaultServiceProvider).saveServer(config, credentials);
    ref.invalidateSelf();
  }

  Future<void> delete(String id) async {
    final current = state.asData?.value;
    if (current != null) {
      // Drop the row before the dismiss animation finishes, then persist.
      state = AsyncData(current.where((server) => server.id != id).toList());
    }
    await ref.read(vaultServiceProvider).deleteServer(id);
  }
}

final knownHostListProvider =
    AsyncNotifierProvider<KnownHostListNotifier, List<KnownHost>>(
  KnownHostListNotifier.new,
);

/// Accepted host keys. The Phase 2 connection flow reads this list.
class KnownHostListNotifier extends AsyncNotifier<List<KnownHost>> {
  @override
  Future<List<KnownHost>> build() {
    return ref.watch(vaultServiceProvider).listKnownHosts();
  }

  Future<void> save(KnownHost knownHost) async {
    await ref.read(vaultServiceProvider).saveKnownHost(knownHost);
    ref.invalidateSelf();
  }

  Future<void> delete(String host, int port) async {
    await ref.read(vaultServiceProvider).deleteKnownHost(host, port);
    ref.invalidateSelf();
  }
}
