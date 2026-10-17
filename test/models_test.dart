import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/known_host.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';

void main() {
  final created = DateTime.utc(2026, 1, 2, 3, 4, 5);
  final updated = DateTime.utc(2026, 2, 3, 4, 5, 6);

  ServerConfig sampleConfig() {
    return ServerConfig(
      id: 'server-1',
      label: 'Build box',
      host: 'example.com',
      username: 'ada',
      authType: AuthType.privateKey,
      createdAt: created,
      updatedAt: updated,
    );
  }

  test('server config json omits secrets and round-trips', () {
    final config = sampleConfig();
    final json = config.toJson();

    expect(json.keys, isNot(contains('password')));
    expect(json.keys, isNot(contains('privateKey')));
    expect(json.keys, isNot(contains('passphrase')));
    expect(json['port'], 22);
    expect(json['authType'], 'privateKey');
    expect(ServerConfig.fromJson(json), config);
  });

  test('server config copyWith and equality', () {
    final config = sampleConfig();
    final renamed = config.copyWith(label: 'Other');

    expect(renamed.label, 'Other');
    expect(renamed.id, config.id);
    expect(renamed, isNot(config));
    expect(config, sampleConfig());
    expect(config.fieldErrors, isEmpty);
  });

  test('server config reports field errors', () {
    final config = sampleConfig().copyWith(
      label: '  ',
      host: 'bad host',
      port: 0,
    );
    final errors = config.fieldErrors;

    expect(errors['label'], isNotNull);
    expect(errors['host'], isNotNull);
    expect(errors['port'], isNotNull);
  });

  test('credentials redact secrets and round-trip', () {
    const credentials = ServerCredentials(
      password: 's3cret',
      privateKey: 'key-body',
      passphrase: 'passphrase-value',
    );

    expect(credentials.toString(), isNot(contains('s3cret')));
    expect(credentials.toString(), isNot(contains('key-body')));
    expect(credentials.toString(), isNot(contains('passphrase-value')));
    expect(ServerCredentials.fromJson(credentials.toJson()), credentials);

    final cleared = credentials.copyWith(password: null);
    expect(cleared.password, isNull);
    expect(cleared.privateKey, 'key-body');
    expect(cleared.toJson().containsKey('password'), isFalse);
  });

  test('known host json round-trips', () {
    final host = KnownHost(
      host: 'example.com',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:abc',
      addedAt: created,
    );

    expect(KnownHost.fromJson(host.toJson()), host);
    expect(host.copyWith(port: 2222).port, 2222);
    expect(host.fieldErrors, isEmpty);
  });

  test('auth type parses stored names', () {
    expect(AuthType.parse('password'), AuthType.password);
    expect(AuthType.parse('privateKey'), AuthType.privateKey);
    expect(() => AuthType.parse('key'), throwsFormatException);
  });
}
