import 'dart:convert';

import 'package:hive/hive.dart';
import 'package:ssh_app/models/known_host.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/ssh_key_record.dart';
import 'package:ssh_app/services/metadata_store.dart';
import 'package:ssh_app/services/vault_exception.dart';

/// Hive boxes for server metadata and accepted host keys.
///
/// Call [Hive.initFlutter] before [HiveMetadataStore.open].
class HiveMetadataStore implements MetadataStore {
  HiveMetadataStore(this._servers, this._hosts, this._keys);

  static const serversBoxName = 'server_configs';
  static const knownHostsBoxName = 'known_hosts';
  static const keysBoxName = 'ssh_keys';

  final Box<String> _servers;
  final Box<String> _hosts;
  final Box<String> _keys;

  static Future<HiveMetadataStore> open() async {
    final servers = await Hive.openBox<String>(serversBoxName);
    final hosts = await Hive.openBox<String>(knownHostsBoxName);
    final keys = await Hive.openBox<String>(keysBoxName);
    return HiveMetadataStore(servers, hosts, keys);
  }

  @override
  Future<List<ServerConfig>> listServers() async {
    final servers = <ServerConfig>[];
    for (final value in _servers.values) {
      servers.add(_readServer(value));
    }
    servers.sort(
      (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    );
    return servers;
  }

  @override
  Future<ServerConfig?> getServer(String id) async {
    final raw = _servers.get(id);
    if (raw == null) {
      return null;
    }
    return _readServer(raw);
  }

  @override
  Future<void> putServer(ServerConfig config) {
    return _servers.put(config.id, jsonEncode(config.toJson()));
  }

  @override
  Future<void> deleteServer(String id) {
    return _servers.delete(id);
  }

  @override
  Future<List<KnownHost>> listKnownHosts() async {
    final hosts = <KnownHost>[];
    for (final value in _hosts.values) {
      hosts.add(_readHost(value));
    }
    hosts.sort((a, b) {
      final byHost = a.host.compareTo(b.host);
      if (byHost != 0) {
        return byHost;
      }
      return a.port.compareTo(b.port);
    });
    return hosts;
  }

  @override
  Future<KnownHost?> getKnownHost(String host, int port) async {
    final raw = _hosts.get(_hostKey(host, port));
    if (raw == null) {
      return null;
    }
    return _readHost(raw);
  }

  @override
  Future<void> putKnownHost(KnownHost knownHost) {
    return _hosts.put(
      _hostKey(knownHost.host, knownHost.port),
      jsonEncode(knownHost.toJson()),
    );
  }

  @override
  Future<void> deleteKnownHost(String host, int port) {
    return _hosts.delete(_hostKey(host, port));
  }

  @override
  Future<List<SshKeyRecord>> listKeys() async {
    final keys = [for (final raw in _keys.values) _readKey(raw)];
    keys.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return keys;
  }

  @override
  Future<SshKeyRecord?> getKey(String id) async {
    final raw = _keys.get(id);
    return raw == null ? null : _readKey(raw);
  }

  @override
  Future<void> putKey(SshKeyRecord key) {
    return _keys.put(key.id, jsonEncode(key.toJson()));
  }

  @override
  Future<void> deleteKey(String id) => _keys.delete(id);

  @override
  Future<void> close() async {
    await _servers.close();
    await _hosts.close();
    await _keys.close();
  }

  SshKeyRecord _readKey(String raw) {
    try {
      return SshKeyRecord.fromJson(_decodeObject(raw));
    } on FormatException {
      throw VaultException('A saved SSH key could not be read.');
    }
  }

  /// Hive key for one host/port pair. A null separator keeps the port and
  /// host from running together.
  static String _hostKey(String host, int port) => '$port\u0000$host';

  ServerConfig _readServer(String raw) {
    try {
      return ServerConfig.fromJson(_decodeObject(raw));
    } on FormatException {
      throw VaultException('A saved server could not be read.');
    }
  }

  KnownHost _readHost(String raw) {
    try {
      return KnownHost.fromJson(_decodeObject(raw));
    } on FormatException {
      throw VaultException('A saved host key could not be read.');
    }
  }

  Map<String, dynamic> _decodeObject(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Expected a JSON object.');
    }
    return Map<String, dynamic>.from(decoded);
  }
}
