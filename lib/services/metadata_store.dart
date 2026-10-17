import 'package:ssh_app/models/known_host.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/ssh_key_record.dart';

/// Local storage for non-secret records.
///
/// Hive implements this in the app. Secrets never go through this interface.
abstract interface class MetadataStore {
  Future<List<ServerConfig>> listServers();

  Future<ServerConfig?> getServer(String id);

  Future<void> putServer(ServerConfig config);

  Future<void> deleteServer(String id);

  Future<List<KnownHost>> listKnownHosts();

  Future<KnownHost?> getKnownHost(String host, int port);

  Future<void> putKnownHost(KnownHost knownHost);

  Future<void> deleteKnownHost(String host, int port);

  Future<List<SshKeyRecord>> listKeys();

  Future<SshKeyRecord?> getKey(String id);

  Future<void> putKey(SshKeyRecord key);

  Future<void> deleteKey(String id);

  Future<void> close();
}
