import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/known_host.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/models/ssh_key_record.dart';
import 'package:ssh_app/services/metadata_store.dart';
import 'package:ssh_app/services/private_key_validator.dart';
import 'package:ssh_app/services/secure_store.dart';
import 'package:ssh_app/services/ssh_key_material.dart';
import 'package:ssh_app/services/vault_exception.dart';
import 'package:uuid/uuid.dart';

/// Secure-storage key for one server's credentials.
String credentialStorageKey(String serverId) => 'cred_$serverId';

/// Secure-storage key for one saved SSH key's private key and passphrase.
String keyStorageKey(String keyId) => 'key_$keyId';

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

  /// What to sign in with. For a server that uses a saved key this is that
  /// key's material, resolved from the key store.
  Future<ServerCredentials?> readCredentials(String serverId) {
    return _lock(() async {
      final server = await _metadata.getServer(serverId);
      final keyId = server?.keyId;
      if (server?.authType == AuthType.privateKey && keyId != null) {
        return _readKeyMaterial(keyId);
      }
      return _readCredentials(serverId);
    });
  }

  /// Only what was stored for this server itself, for the edit form. A
  /// server that uses a saved key has no private key of its own.
  Future<ServerCredentials?> readOwnCredentials(String serverId) {
    return _lock(() => _readCredentials(serverId));
  }

  Future<List<SshKeyRecord>> listKeys() => _lock(_metadata.listKeys);

  Future<SshKeyRecord?> getKey(String id) {
    return _lock(() => _metadata.getKey(id));
  }

  /// The private key and passphrase of a saved key.
  Future<ServerCredentials> readKeyMaterial(String keyId) {
    return _lock(() => _readKeyMaterial(keyId));
  }

  /// Saves a key whose [info] came from [inspectPrivateKey] or
  /// [generateKey]. The secret is written first and removed again if the
  /// record cannot be written. The same key (same fingerprint) is not saved
  /// twice.
  Future<SshKeyRecord> addKey({
    required String name,
    required String privateKey,
    String? passphrase,
    required KeyInfo info,
  }) {
    return _lock(() async {
      final trimmed = name.trim();
      if (trimmed.isEmpty) {
        throw VaultValidationException({'name': 'Enter a name for this key.'});
      }
      if (trimmed.length > 60) {
        throw VaultValidationException({
          'name': 'Use a name of 60 characters or fewer.',
        });
      }
      final existing = await _metadata.listKeys();
      for (final key in existing) {
        if (key.fingerprint == info.fingerprint) {
          throw VaultException('This key is already saved as "${key.name}".');
        }
      }
      final record = SshKeyRecord(
        id: const Uuid().v4(),
        name: trimmed,
        type: info.type,
        publicKey: info.publicKey,
        fingerprint: info.fingerprint,
        encrypted: info.encrypted,
        createdAt: _clock().toUtc(),
      );
      await _writeKey(record, privateKey, info.encrypted ? passphrase : null);
      return record;
    });
  }

  Future<SshKeyRecord> renameKey(String id, String name) {
    return _lock(() async {
      final key = await _metadata.getKey(id);
      if (key == null) {
        throw VaultException('This key no longer exists.');
      }
      final trimmed = name.trim();
      if (trimmed.isEmpty || trimmed.length > 60) {
        throw VaultValidationException({
          'name': 'Use a name of 1 to 60 characters.',
        });
      }
      final renamed = key.copyWith(name: trimmed);
      await _metadata.putKey(renamed);
      return renamed;
    });
  }

  /// The servers that sign in with the saved key [keyId].
  Future<List<ServerConfig>> serversUsingKey(String keyId) {
    return _lock(() => _serversUsingKey(keyId));
  }

  /// Removes a saved key, unless a server still uses it. The secret goes
  /// first, as for servers.
  Future<void> deleteKey(String id) {
    return _lock(() async {
      final users = await _serversUsingKey(id);
      if (users.isNotEmpty) {
        final names = users.map((server) => server.label).join(', ');
        throw VaultException(
          users.length == 1
              ? 'This key is used by $names. Change that host first.'
              : 'This key is used by ${users.length} hosts ($names). '
                    'Change them first.',
        );
      }
      await _secure.delete(keyStorageKey(id));
      await _metadata.deleteKey(id);
    });
  }

  /// Moves private keys pasted into individual servers into the key store.
  ///
  /// Each server then points at its key and its own copy is cleared. The
  /// same key on several servers becomes one entry. Writes are ordered so a
  /// failure never loses a key: the key is stored first, the server points
  /// at it second, and the old copy is removed last. A key that cannot be
  /// read is left where it is. Returns how many servers were migrated.
  Future<int> migratePastedKeys() {
    return _lock(() async {
      var migrated = 0;
      final servers = await _metadata.listServers();
      final byFingerprint = {
        for (final key in await _metadata.listKeys()) key.fingerprint: key,
      };
      final names = {for (final key in byFingerprint.values) key.name};
      for (final server in servers) {
        if (server.authType != AuthType.privateKey) {
          continue;
        }
        final own = await _readCredentials(server.id);
        final pem = own?.privateKey;
        if (pem == null || pem.trim().isEmpty) {
          continue;
        }
        if (server.keyId != null) {
          // Pointed at a key by an earlier run that stopped before clearing.
          await _clearOwnCredentials(server.id);
          continue;
        }
        final KeyInfo info;
        try {
          info = await inspectPrivateKeyInBackground(
            pem,
            own?.passphrase,
            comment: server.label,
          );
        } on FormatException {
          continue;
        }
        var record = byFingerprint[info.fingerprint];
        if (record == null) {
          record = SshKeyRecord(
            id: const Uuid().v4(),
            name: _uniqueName('${server.label} key', names),
            type: info.type,
            publicKey: info.publicKey,
            fingerprint: info.fingerprint,
            encrypted: info.encrypted,
            createdAt: _clock().toUtc(),
          );
          await _writeKey(record, pem.trim(), info.encrypted ? own?.passphrase : null);
          byFingerprint[info.fingerprint] = record;
          names.add(record.name);
        }
        await _metadata.putServer(server.copyWith(keyId: record.id));
        await _clearOwnCredentials(server.id);
        migrated++;
      }
      return migrated;
    });
  }

  String _uniqueName(String base, Set<String> taken) {
    if (!taken.contains(base)) {
      return base;
    }
    for (var n = 2;; n++) {
      final candidate = '$base $n';
      if (!taken.contains(candidate)) {
        return candidate;
      }
    }
  }

  Future<void> _clearOwnCredentials(String serverId) {
    return _secure.write(
      credentialStorageKey(serverId),
      jsonEncode(const ServerCredentials().toJson()),
    );
  }

  Future<List<ServerConfig>> _serversUsingKey(String keyId) async {
    return [
      for (final server in await _metadata.listServers())
        if (server.keyId == keyId && server.authType == AuthType.privateKey)
          server,
    ];
  }

  Future<void> _writeKey(
    SshKeyRecord record,
    String privateKey,
    String? passphrase,
  ) async {
    final secretKey = keyStorageKey(record.id);
    try {
      await _secure.write(
        secretKey,
        jsonEncode(
          ServerCredentials(
            privateKey: privateKey,
            passphrase: passphrase,
          ).toJson(),
        ),
      );
    } catch (error) {
      throw VaultException(
        'Could not save the key to secure storage. $error',
      );
    }
    try {
      await _metadata.putKey(record);
    } catch (error) {
      await _secure.delete(secretKey);
      throw VaultException('Could not save the key. $error');
    }
  }

  Future<ServerCredentials> _readKeyMaterial(String keyId) async {
    final raw = await _secure.read(keyStorageKey(keyId));
    if (raw == null) {
      throw VaultException(
        'The saved key for this host is missing. Pick another key in the '
        'host settings.',
      );
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('Expected a JSON object.');
      }
      return ServerCredentials.fromJson(Map<String, dynamic>.from(decoded));
    } on FormatException {
      throw VaultException('A saved key could not be read.');
    }
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
    var normalized = config.normalized();
    if (normalized.authType != AuthType.privateKey) {
      // A password host has no key.
      normalized = normalized.copyWith(clearKeyId: true);
    }
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
        final keyId = config.keyId;
        if (keyId != null) {
          // The key material is read from the key store when connecting.
          if (await _metadata.getKey(keyId) == null) {
            errors['keyId'] = 'That saved key no longer exists. Pick another.';
          }
          return const ServerCredentials();
        }
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
