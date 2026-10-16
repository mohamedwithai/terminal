import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/known_host.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/services/flutter_secure_store.dart';
import 'package:ssh_app/services/metadata_store.dart';
import 'package:ssh_app/services/secure_context.dart'
    if (dart.library.js_interop) 'package:ssh_app/services/secure_context_web.dart';
import 'package:ssh_app/services/secure_store.dart';
import 'package:ssh_app/services/vault_service.dart';

/// Opened in `main` with [HiveMetadataStore]. Tests override this.
final metadataStoreProvider = Provider<MetadataStore>((ref) {
  throw StateError('metadataStoreProvider must be overridden at startup.');
});

final secureStoreProvider = Provider<SecureStore>((ref) {
  return FlutterSecureStore();
});

/// False on the web when the page is served over plain HTTP from a host
/// other than localhost. Secure storage cannot encrypt there, so the UI
/// disables saving.
final secureStorageAvailableProvider = Provider<bool>((ref) {
  return isSecureContext();
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

  /// Notes a successful connection, for "last connected" on the list.
  Future<void> recordConnected(String id, DateTime at) async {
    final updated =
        await ref.read(vaultServiceProvider).recordConnected(id, at);
    final current = state.asData?.value;
    if (updated != null && current != null) {
      state = AsyncData([
        for (final server in current) server.id == id ? updated : server,
      ]);
    }
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
