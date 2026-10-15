import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/host_validator.dart';
import 'package:uuid/uuid.dart';

/// Non-secret connection details for one saved server.
///
/// Passwords and private keys live in [ServerCredentials], never here.
/// This object is safe to store in Hive and to pass through widget routes.
class ServerConfig {
  /// Creates a server record. Prefer [ServerConfig.create] for new servers.
  const ServerConfig({
    required this.id,
    required this.label,
    required this.host,
    this.port = 22,
    required this.username,
    required this.authType,
    required this.createdAt,
    required this.updatedAt,
  });

  /// New server with a UUID and matching created/updated timestamps.
  factory ServerConfig.create({
    String? id,
    required String label,
    required String host,
    int port = 22,
    required String username,
    required AuthType authType,
    DateTime? now,
  }) {
    final timestamp = (now ?? DateTime.now()).toUtc();
    return ServerConfig(
      id: id ?? const Uuid().v4(),
      label: label,
      host: host,
      port: port,
      username: username,
      authType: authType,
      createdAt: timestamp,
      updatedAt: timestamp,
    );
  }

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    return ServerConfig(
      id: _requiredString(json, 'id'),
      label: _requiredString(json, 'label'),
      host: _requiredString(json, 'host'),
      port: _requiredPort(json['port']),
      username: _requiredString(json, 'username'),
      authType: AuthType.parse(_requiredString(json, 'authType')),
      createdAt: _requiredDate(json, 'createdAt'),
      updatedAt: _requiredDate(json, 'updatedAt'),
    );
  }

  final String id;
  final String label;
  final String host;
  final int port;
  final String username;
  final AuthType authType;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Field messages for the add/edit form. Empty when the record is usable.
  Map<String, String> get fieldErrors {
    final errors = <String, String>{};
    if (id.trim().isEmpty) {
      errors['id'] = 'Missing server id.';
    }
    final trimmedLabel = label.trim();
    if (trimmedLabel.isEmpty) {
      errors['label'] = 'Enter a name for this server.';
    } else if (trimmedLabel.length > 80) {
      errors['label'] = 'Use a name of 80 characters or fewer.';
    }
    final trimmedHost = host.trim();
    if (trimmedHost.isEmpty) {
      errors['host'] = 'Enter a hostname or IP address.';
    } else if (!isValidHost(trimmedHost)) {
      errors['host'] =
          'Enter a valid hostname, IPv4 address, or IPv6 address.';
    }
    if (port < 1 || port > 65535) {
      errors['port'] = 'Enter a port from 1 to 65535.';
    }
    final trimmedUser = username.trim();
    if (trimmedUser.isEmpty) {
      errors['username'] = 'Enter the SSH username.';
    } else if (trimmedUser.length > 128 || RegExp(r'\s').hasMatch(trimmedUser)) {
      errors['username'] = 'Enter a username without spaces.';
    }
    return errors;
  }

  /// Trimmed copy used before the record is written to Hive.
  ServerConfig normalized() {
    return copyWith(
      label: label.trim(),
      host: host.trim(),
      username: username.trim(),
    );
  }

  ServerConfig copyWith({
    String? id,
    String? label,
    String? host,
    int? port,
    String? username,
    AuthType? authType,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return ServerConfig(
      id: id ?? this.id,
      label: label ?? this.label,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      authType: authType ?? this.authType,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'label': label,
      'host': host,
      'port': port,
      'username': username,
      'authType': authType.name,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
    };
  }

  @override
  bool operator ==(Object other) {
    return other is ServerConfig &&
        other.id == id &&
        other.label == label &&
        other.host == host &&
        other.port == port &&
        other.username == username &&
        other.authType == authType &&
        other.createdAt.toUtc() == createdAt.toUtc() &&
        other.updatedAt.toUtc() == updatedAt.toUtc();
  }

  @override
  int get hashCode => Object.hash(
        id,
        label,
        host,
        port,
        username,
        authType,
        createdAt.toUtc(),
        updatedAt.toUtc(),
      );

  @override
  String toString() {
    return 'ServerConfig(id: $id, label: $label, host: $host, port: $port, '
        'username: $username, authType: ${authType.name})';
  }
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('Server config is missing "$key".');
  }
  return value;
}

int _requiredPort(Object? value) {
  if (value is! num) {
    throw const FormatException('Server config is missing "port".');
  }
  return value.toInt();
}

DateTime _requiredDate(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('Server config is missing "$key".');
  }
  return DateTime.parse(value).toUtc();
}
