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
    this.tags = const [],
    this.lastConnectedAt,
    this.keyId,
  });

  /// New server with a UUID and matching created/updated timestamps.
  factory ServerConfig.create({
    String? id,
    required String label,
    required String host,
    int port = 22,
    required String username,
    required AuthType authType,
    List<String> tags = const [],
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
      tags: tags,
    );
  }

  /// Reads a stored record. `tags` and `lastConnectedAt` are optional, so
  /// records saved by older versions still load.
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
      tags: _optionalTags(json['tags']),
      lastConnectedAt: _optionalDate(json['lastConnectedAt']),
      keyId: json['keyId'] is String && (json['keyId'] as String).isNotEmpty
          ? json['keyId'] as String
          : null,
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

  /// Labels such as "Personal" or "Clients", for filtering the host list.
  final List<String> tags;

  /// When a connection to this server last succeeded, if ever.
  final DateTime? lastConnectedAt;

  /// The saved SSH key this server signs in with, when its auth type is a
  /// private key and the key comes from the key store. Null means the key
  /// was pasted for this server alone.
  final String? keyId;

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
    final cleanTags = <String>[];
    for (final tag in tags) {
      final trimmed = tag.trim();
      if (trimmed.isNotEmpty && !cleanTags.contains(trimmed)) {
        cleanTags.add(trimmed);
      }
    }
    return copyWith(
      label: label.trim(),
      host: host.trim(),
      username: username.trim(),
      tags: cleanTags,
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
    List<String>? tags,
    DateTime? lastConnectedAt,
    String? keyId,
    bool clearKeyId = false,
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
      tags: tags ?? this.tags,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
      keyId: clearKeyId ? null : keyId ?? this.keyId,
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
      'tags': tags,
      if (lastConnectedAt != null)
        'lastConnectedAt': lastConnectedAt!.toUtc().toIso8601String(),
      if (keyId != null) 'keyId': keyId,
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
        other.updatedAt.toUtc() == updatedAt.toUtc() &&
        _sameTags(other.tags, tags) &&
        other.lastConnectedAt?.toUtc() == lastConnectedAt?.toUtc() &&
        other.keyId == keyId;
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
        Object.hashAll(tags),
        lastConnectedAt?.toUtc(),
        keyId,
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

List<String> _optionalTags(Object? value) {
  if (value is! List) {
    return const [];
  }
  return [for (final tag in value) if (tag is String) tag];
}

DateTime? _optionalDate(Object? value) {
  return value is String ? DateTime.tryParse(value)?.toUtc() : null;
}

bool _sameTags(List<String> a, List<String> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

DateTime _requiredDate(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('Server config is missing "$key".');
  }
  return DateTime.parse(value).toUtc();
}
