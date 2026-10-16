import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/known_host.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/services/metadata_store.dart';
import 'package:ssh_app/services/private_key_validator.dart';
import 'package:ssh_app/services/secure_store.dart';
import 'package:ssh_app/services/vault_exception.dart';

/// Secure-storage key for one server's credentials.
String credentialStorageKey(String serverId) => 'cred_$serverId';

/// Saves server metadata in [MetadataStore] and secrets in [SecureStore].
///
/// Deleting a server removes both records. A failed private-key parse
/// writes nothing.
class VaultService {
  VaultService({
    required SecureStore secureStore,
    required MetadataStore metadataStore,
    DateTime Function()? clock,
    Future<void> Function(String privateKey, String? passphrase)?
        validatePrivateKey,
  })  : _secure = secureStore,
        _metadata = metadataStore,
        _clock = clock ?? DateTime.now,
        _validatePrivateKey = validatePrivateKey ?? validatePrivateKeyMaterial;

  final SecureStore _secure;
  final MetadataStore _metadata;
  final DateTime Function() _clock;
  final Future<void> Function(String privateKey, String? passphrase)
      _validatePrivateKey;

  Future<void> _tail = Future<void>.value();

  Future<List<ServerConfig>> listServers() {
    return _lock(_metadata.listServers);
  }

  Future<ServerConfig?> getServer(String id) {
    return _lock(() => _metadata.getServer(id));
  }

  Future<ServerCredentials?> readCredentials(String serverId) {
    return _lock(() => _readCredentials(serverId));
  }

  /// Inserts or replaces [config] and its secrets.
  ///
  /// Returns the record that was stored, including the vault's timestamps.
  Future<ServerConfig> saveServer(
    ServerConfig config,
    ServerCredentials credentials,
  ) {
    return _lock(() => _saveServer(config, credentials));
  }

  /// Records a successful connection to [serverId] at [at]. Only the
  /// metadata changes; returns the updated record, or null if the server is
  /// gone.
  Future<ServerConfig?> recordConnected(String serverId, DateTime at) {
    return _lock(() async {
      final server = await _metadata.getServer(serverId);
      if (server == null) {
        return null;
      }
      final updated = server.copyWith(lastConnectedAt: at.toUtc());
      await _metadata.putServer(updated);
      return updated;
    });
  }

  /// Removes the Hive record and the `cred_<id>` secret.
  Future<void> deleteServer(String id) {
    return _lock(() => _deleteServer(id));
  }

  Future<List<KnownHost>> listKnownHosts() {
    return _lock(_metadata.listKnownHosts);
  }

  Future<KnownHost?> getKnownHost(String host, int port) {
    return _lock(() => _metadata.getKnownHost(host, port));
  }

  /// Remembers a host key. The same host and port replace the previous key.
  Future<void> saveKnownHost(KnownHost knownHost) {
    return _lock(() => _saveKnownHost(knownHost));
  }

  Future<void> deleteKnownHost(String host, int port) {
    return _lock(() => _metadata.deleteKnownHost(host, port));
  }

  Future<T> _lock<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<ServerConfig> _saveServer(
    ServerConfig config,
    ServerCredentials credentials,
  ) async {
    final normalized = config.normalized();
    final errors = normalized.fieldErrors;
    final storedCredentials = await _credentialsFor(normalized, credentials, errors);
    if (errors.isNotEmpty) {
      throw VaultValidationException(errors);
    }

    final existing = await _metadata.getServer(normalized.id);
    final now = _clock().toUtc();
    final stored = normalized.copyWith(
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      // The form does not edit this; keep what the vault recorded.
      lastConnectedAt: existing?.lastConnectedAt,
    );
    final key = credentialStorageKey(stored.id);
    try {
      await _secure.write(key, jsonEncode(storedCredentials.toJson()));
    } catch (error) {
      // Nothing has been written yet. Platform stores fail with their own
      // types, including Errors such as the web store's UnsupportedError.
      throw VaultException(
        'Could not save the credentials to secure storage. $error',
      );
    }
    try {
      await _metadata.putServer(stored);
    } catch (error) {
      // A brand-new server should not stay half-written. An update keeps
      // the new secret: the previous ciphertext was already replaced.
      if (existing == null) {
        await _secure.delete(key);
      }
      throw VaultException('Could not save the server. $error');
    }
    return stored;
  }

  Future<ServerCredentials> _credentialsFor(
    ServerConfig config,
    ServerCredentials credentials,
    Map<String, String> errors,
  ) async {
    switch (config.authType) {
      case AuthType.password:
        final password = credentials.password ?? '';
        if (password.isEmpty) {
          errors['password'] = 'Enter the password for this server.';
        }
        return ServerCredentials(password: password.isEmpty ? null : password);
      case AuthType.privateKey:
        final privateKey = credentials.privateKey?.trim() ?? '';
        final passphrase = _blankToNull(credentials.passphrase);
        if (privateKey.isEmpty) {
          errors['privateKey'] = 'Paste an OpenSSH or PEM private key.';
          return const ServerCredentials();
        }
        try {
          await _validatePrivateKey(privateKey, passphrase);
        } on PrivateKeyValidationException catch (error) {
          errors[error.field] = error.message;
          return const ServerCredentials();
        }
        if (errors.isNotEmpty) {
          return const ServerCredentials();
        }
        final encrypted = SSHKeyPair.isEncryptedPem(privateKey);
        return ServerCredentials(
          privateKey: privateKey,
          passphrase: encrypted ? passphrase : null,
        );
    }
  }

  Future<void> _deleteServer(String id) async {
    // The secret goes first. If that fails, the server stays in the list
    // and the credentials are still there for a retry.
    await _secure.delete(credentialStorageKey(id));
    await _metadata.deleteServer(id);
  }

  Future<ServerCredentials?> _readCredentials(String serverId) async {
    final raw = await _secure.read(credentialStorageKey(serverId));
    if (raw == null) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('Expected a JSON object.');
      }
      return ServerCredentials.fromJson(Map<String, dynamic>.from(decoded));
    } on FormatException {
      throw VaultException('Saved credentials could not be read.');
    }
  }

  Future<void> _saveKnownHost(KnownHost knownHost) async {
    final errors = knownHost.fieldErrors;
    if (errors.isNotEmpty) {
      throw VaultValidationException(errors);
    }
    await _metadata.putKnownHost(
      knownHost.copyWith(
        host: knownHost.host.trim(),
        keyType: knownHost.keyType.trim(),
        fingerprint: knownHost.fingerprint.trim(),
      ),
    );
  }

  String? _blankToNull(String? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }
}
