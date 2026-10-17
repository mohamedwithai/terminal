import 'dart:convert';

import 'package:ssh_app/models/known_host.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/ssh_key_record.dart';
import 'package:ssh_app/services/metadata_store.dart';
import 'package:ssh_app/services/secure_store.dart';

/// In-memory [SecureStore] for unit tests.
class MemorySecureStore implements SecureStore {
  final Map<String, String> values = {};

  @override
  Future<bool> containsKey(String key) async => values.containsKey(key);

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

/// [SecureStore] whose writes fail with [error], like a Keystore fault or
/// the web store outside a secure context.
class FailingSecureStore extends MemorySecureStore {
  FailingSecureStore([Object? error])
    : error = error ?? UnsupportedError('Secure storage is unavailable.');

  final Object error;

  @override
  Future<void> write(String key, String value) async {
    throw error;
  }
}

/// In-memory [MetadataStore] for unit tests.
class MemoryMetadataStore implements MetadataStore {
  final Map<String, String> servers = {};
  final Map<String, String> knownHosts = {};
  final Map<String, String> keys = {};

  @override
  Future<List<SshKeyRecord>> listKeys() async {
    final all = keys.values
        .map((raw) => SshKeyRecord.fromJson(_object(raw)))
        .toList();
    all.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return all;
  }

  @override
  Future<SshKeyRecord?> getKey(String id) async {
    final raw = keys[id];
    return raw == null ? null : SshKeyRecord.fromJson(_object(raw));
  }

  @override
  Future<void> putKey(SshKeyRecord key) async {
    keys[key.id] = jsonEncode(key.toJson());
  }

  @override
  Future<void> deleteKey(String id) async {
    keys.remove(id);
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> deleteKnownHost(String host, int port) async {
    knownHosts.remove(_hostKey(host, port));
  }

  @override
  Future<void> deleteServer(String id) async {
    servers.remove(id);
  }

  @override
  Future<KnownHost?> getKnownHost(String host, int port) async {
    final raw = knownHosts[_hostKey(host, port)];
    if (raw == null) {
      return null;
    }
    return KnownHost.fromJson(_object(raw));
  }

  @override
  Future<ServerConfig?> getServer(String id) async {
    final raw = servers[id];
    if (raw == null) {
      return null;
    }
    return ServerConfig.fromJson(_object(raw));
  }

  @override
  Future<List<KnownHost>> listKnownHosts() async {
    final hosts = knownHosts.values
        .map((raw) => KnownHost.fromJson(_object(raw)))
        .toList();
    hosts.sort((a, b) {
      final byHost = a.host.compareTo(b.host);
      return byHost != 0 ? byHost : a.port.compareTo(b.port);
    });
    return hosts;
  }

  @override
  Future<List<ServerConfig>> listServers() async {
    final configs = servers.values
        .map((raw) => ServerConfig.fromJson(_object(raw)))
        .toList();
    configs.sort(
      (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    );
    return configs;
  }

  @override
  Future<void> putKnownHost(KnownHost knownHost) async {
    knownHosts[_hostKey(knownHost.host, knownHost.port)] = jsonEncode(
      knownHost.toJson(),
    );
  }

  @override
  Future<void> putServer(ServerConfig config) async {
    servers[config.id] = jsonEncode(config.toJson());
  }

  String _hostKey(String host, int port) => '$port\u0000$host';

  Map<String, dynamic> _object(String raw) {
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }
}
