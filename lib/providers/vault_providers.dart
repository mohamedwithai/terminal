import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:ssh_app/models/ssh_key_record.dart';
import 'package:ssh_app/providers/app_lock_providers.dart';
import 'package:ssh_app/providers/preferences_providers.dart';
import 'package:ssh_app/services/ssh_key_material.dart';
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
  /// Set once keys pasted into individual servers have been moved into the
  /// key store.
  static const keysMigratedKey = 'keys_migrated';

  @override
  Future<List<ServerConfig>> build() async {
    final vault = ref.watch(vaultServiceProvider);
    await _migratePastedKeysOnce(vault);
    return vault.listServers();
  }

  Future<void> _migratePastedKeysOnce(VaultService vault) async {
    final preferences = ref.read(preferencesStoreProvider);
    if (preferences.getBool(keysMigratedKey)) {
      return;
    }
    try {
      await vault.migratePastedKeys();
      await preferences.setBool(keysMigratedKey, true);
    } catch (error) {
      // Servers keep working with their own keys; it is tried again on the
      // next start.
      debugPrint('Could not move pasted keys into the key store: $error');
    }
  }

  Future<void> save(ServerConfig config, ServerCredentials credentials) async {
    await ref.read(vaultServiceProvider).saveServer(config, credentials);
    ref.invalidateSelf();
  }

  /// Notes a successful connection, for "last connected" on the list.
  Future<void> recordConnected(String id, DateTime at) async {
    final updated = await ref
        .read(vaultServiceProvider)
        .recordConnected(id, at);
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

/// Saved SSH keys. Waits for the server list so the one-time migration of
/// pasted keys has finished, and reloads when servers change.
final keyListProvider =
    AsyncNotifierProvider<KeyListNotifier, List<SshKeyRecord>>(
      KeyListNotifier.new,
    );

class KeyListNotifier extends AsyncNotifier<List<SshKeyRecord>> {
  @override
  Future<List<SshKeyRecord>> build() async {
    await ref.watch(serverListProvider.future);
    return ref.watch(vaultServiceProvider).listKeys();
  }

  Future<SshKeyRecord> add({
    required String name,
    required String privateKey,
    String? passphrase,
    required KeyInfo info,
  }) async {
    final record = await ref
        .read(vaultServiceProvider)
        .addKey(
          name: name,
          privateKey: privateKey,
          passphrase: passphrase,
          info: info,
        );
    ref.invalidateSelf();
    return record;
  }

  Future<void> rename(String id, String name) async {
    await ref.read(vaultServiceProvider).renameKey(id, name);
    ref.invalidateSelf();
  }

  Future<void> delete(String id) async {
    await ref.read(vaultServiceProvider).deleteKey(id);
    ref.invalidateSelf();
  }
}

/// Opens the system file picker and returns the chosen file's text, or null
/// if nothing was chosen. Tests replace it.
final keyFilePickerProvider = Provider<Future<String?> Function()>((ref) {
  // The picker is another screen, which must not count as leaving the app
  // (that would lock it on return).
  return () => ref.read(appLockProvider.notifier).runExternal(() async {
    final files = await FilePicker.pickFiles(dialogTitle: 'Choose a file');
    if (files.isEmpty) {
      return null;
    }
    final bytes = await files.first.readAsBytes();
    if (bytes.length > 64 * 1024) {
      throw const FormatException('This file is too large to be an SSH key.');
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const FormatException(
        'This file is not text, so it cannot be an OpenSSH or PEM key.',
      );
    }
  });
});

/// Opens the system share sheet with [text]. Tests replace it.
final shareTextProvider =
    Provider<Future<void> Function(String text, String subject)>((ref) {
      return (text, subject) => ref
          .read(appLockProvider.notifier)
          .runExternal(
            () => SharePlus.instance.share(
              ShareParams(text: text, subject: subject),
            ),
          );
    });
