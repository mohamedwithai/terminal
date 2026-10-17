@Tags(['live'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/known_host.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/services/sftp/remote_file_system.dart';
import 'package:ssh_app/services/sftp/sftp_file_system.dart';
import 'package:ssh_app/services/sftp/sftp_opener.dart';
import 'package:ssh_app/services/ssh/host_key_verifier.dart';
import 'package:ssh_app/services/ssh/ssh_connection_service.dart';
import 'package:ssh_app/services/vault_service.dart';

import 'support/memory_stores.dart';

/// LIVE SFTP TEST against a real server. Skipped unless the target is given;
/// there are no default hosts, users or passwords. It works inside a folder
/// it creates and removes under the login's home directory.
///
///   flutter test --tags live --run-skipped test/sftp_live_test.dart
///
/// SSH_TEST_HOST, SSH_TEST_USER, SSH_TEST_PORT (default 22), and either
/// SSH_TEST_PASSWORD or SSH_TEST_KEY_PATH (+ SSH_TEST_KEY_PASSPHRASE).
void main() {
  final env = Platform.environment;
  final host = env['SSH_TEST_HOST'];
  final user = env['SSH_TEST_USER'];
  final password = env['SSH_TEST_PASSWORD'];
  final keyPath = env['SSH_TEST_KEY_PATH'];
  final port = int.tryParse(env['SSH_TEST_PORT'] ?? '') ?? 22;
  final ready =
      host != null && user != null && (password != null || keyPath != null);

  late SSHClient client;
  late SftpFileSystem files;
  late String base;

  setUp(() async {
    if (!ready) return;
    client = SSHClient(
      await SSHSocket.connect(host, port),
      username: user,
      identities: keyPath == null
          ? null
          : SSHKeyPair.fromPem(
              File(keyPath).readAsStringSync(),
              env['SSH_TEST_KEY_PASSPHRASE'],
            ),
      onPasswordRequest: () => password,
    );
    await client.authenticated;
    files = SftpFileSystem(await client.sftp());
    base = joinRemote(
      await files.home(),
      'ssh_app_sftp_live_${DateTime.now().microsecondsSinceEpoch}',
    );
    await files.createFolder(base);
  });

  tearDown(() async {
    if (!ready) return;
    try {
      await files.delete(base, isDirectory: true);
    } catch (_) {}
    await files.close();
    client.close();
  });

  Uint8List randomBytes(int n) {
    final random = Random(42);
    return Uint8List.fromList(List.generate(n, (_) => random.nextInt(256)));
  }

  Future<Uint8List> read(String path) async {
    final out = BytesBuilder();
    await for (final chunk in files.download(path)) {
      out.add(chunk);
    }
    return out.takeBytes();
  }

  test('upload, list, download, rename, delete', () async {
    if (!ready) return;
    final data = randomBytes(700 * 1024 + 13);
    final progress = <int>[];

    await files.upload(
      joinRemote(base, 'data.bin'),
      Stream.fromIterable([
        for (var i = 0; i < data.length; i += 32768)
          Uint8List.sublistView(data, i, min(i + 32768, data.length)),
      ]),
      total: data.length,
      onProgress: (bytes, total) => progress.add(bytes),
    );
    expect(progress, isNotEmpty);
    expect(progress.last, data.length);

    final listing = await files.list(base);
    final entry = listing.singleWhere((e) => e.name == 'data.bin');
    expect(entry.isDirectory, isFalse);
    expect(entry.size, data.length);
    expect(entry.modified, isNotNull);
    expect(entry.permissions, hasLength(9));

    final downloadProgress = <int>[];
    final out = BytesBuilder();
    await for (final chunk in files.download(
      joinRemote(base, 'data.bin'),
      onProgress: (b, t) => downloadProgress.add(b),
    )) {
      out.add(chunk);
    }
    expect(out.takeBytes(), data);
    expect(downloadProgress.last, data.length);

    await files.rename(
      joinRemote(base, 'data.bin'),
      joinRemote(base, 'renamed.bin'),
    );
    expect((await files.list(base)).map((e) => e.name), ['renamed.bin']);

    await files.delete(joinRemote(base, 'renamed.bin'), isDirectory: false);
    expect(await files.list(base), isEmpty);
  });

  test('folders: create, nest, count, delete everything inside', () async {
    if (!ready) return;
    await files.createFolder(joinRemote(base, 'a'));
    await files.createFolder(joinRemote(base, 'a/b'));
    for (final path in ['a/one.txt', 'a/b/two.txt', 'a/b/three.txt']) {
      await files.upload(
        joinRemote(base, path),
        Stream.value(Uint8List.fromList(path.codeUnits)),
      );
    }

    final top = await files.list(base);
    expect(top.single.name, 'a');
    expect(top.single.isDirectory, isTrue);
    expect(await files.countEntries(joinRemote(base, 'a')), 4);

    await files.delete(joinRemote(base, 'a'), isDirectory: true);
    expect(await files.list(base), isEmpty);
  });

  test('a file with spaces and unicode in its name round-trips', () async {
    if (!ready) return;
    const name = 'my résumé (final) 日本語.txt';
    await files.upload(
      joinRemote(base, name),
      Stream.value(Uint8List.fromList('hi'.codeUnits)),
    );
    expect((await files.list(base)).single.name, name);
    expect(String.fromCharCodes(await read(joinRemote(base, name))), 'hi');
  });

  test('cancelling an upload leaves no partial file', () async {
    if (!ready) return;
    final cancel = TransferCancel();
    final chunk = randomBytes(32768);
    var sent = 0;
    Stream<Uint8List> slow() async* {
      for (var i = 0; i < 200; i++) {
        yield chunk;
        sent++;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    final upload = files.upload(
      joinRemote(base, 'partial.bin'),
      slow(),
      cancel: cancel,
      onProgress: (bytes, total) {
        if (bytes > 100000) cancel.cancel();
      },
    );
    await expectLater(upload, throwsA(isA<TransferCancelled>()));

    expect(sent, lessThan(200));
    expect(
      (await files.list(base)).map((e) => e.name),
      isNot(contains('partial.bin')),
    );
  });

  test('cancelling a download stops it', () async {
    if (!ready) return;
    await files.upload(
      joinRemote(base, 'big.bin'),
      Stream.value(randomBytes(2 * 1024 * 1024)),
    );
    final cancel = TransferCancel();
    var received = 0;
    final result = () async {
      await for (final chunk in files.download(
        joinRemote(base, 'big.bin'),
        cancel: cancel,
      )) {
        received += chunk.length;
        cancel.cancel();
      }
    }();
    await expectLater(result, throwsA(isA<TransferCancelled>()));
    expect(received, lessThan(2 * 1024 * 1024));
  });

  test('errors become readable messages', () async {
    if (!ready) return;
    await expectLater(
      files.list(joinRemote(base, 'nope')),
      throwsA(
        isA<RemoteFileException>().having(
          (e) => e.message,
          'message',
          anyOf(contains('no longer exists'), contains('No such file')),
        ),
      ),
    );
    await expectLater(
      files.download(joinRemote(base, 'nope.txt')).toList(),
      throwsA(isA<RemoteFileException>()),
    );
    await expectLater(
      files.createFolder(joinRemote(base, 'x/y/z')),
      throwsA(isA<RemoteFileException>()),
    );
  });

  test('the opener refuses a host key it does not know', () async {
    if (!ready) return;
    final server = ServerConfig.create(
      label: 'live',
      host: host,
      port: port,
      username: user,
      authType: password != null ? AuthType.password : AuthType.privateKey,
    );
    final vault = VaultService(
      secureStore: MemorySecureStore(),
      metadataStore: MemoryMetadataStore(),
    );
    await vault.saveServer(
      server,
      ServerCredentials(
        password: password,
        privateKey: keyPath == null ? null : File(keyPath).readAsStringSync(),
        passphrase: env['SSH_TEST_KEY_PASSPHRASE'],
      ),
    );
    final opener = SshSftpOpener(
      connections: SSHConnectionService(
        hostKeyVerifier: HostKeyVerifier(
          findKnownHost: (host, port) async => null,
          saveKnownHost: (known) async {},
        ),
      ),
      vault: vault,
    );

    await expectLater(
      opener.open(server),
      throwsA(
        isA<RemoteFileException>().having(
          (e) => e.message,
          'message',
          contains('Host key not trusted yet'),
        ),
      ),
    );
  });

  // The server's host key, as `ssh-keygen -lf` prints it. With it the opener
  // can be tried on a trusted host.
  final fingerprint = env['SSH_TEST_HOST_FINGERPRINT'];
  final keyType = env['SSH_TEST_HOST_KEY_TYPE'] ?? 'ssh-ed25519';

  group('the opener on a trusted host', () {
    late VaultService vault;
    late ServerConfig server;
    late SSHConnectionService connections;

    setUp(() async {
      if (!ready || fingerprint == null) return;
      server = ServerConfig.create(
        label: 'live',
        host: host,
        port: port,
        username: user,
        authType: password != null ? AuthType.password : AuthType.privateKey,
      );
      vault = VaultService(
        secureStore: MemorySecureStore(),
        metadataStore: MemoryMetadataStore(),
      );
      await vault.saveServer(
        server,
        ServerCredentials(
          password: password,
          privateKey: keyPath == null ? null : File(keyPath).readAsStringSync(),
          passphrase: env['SSH_TEST_KEY_PASSPHRASE'],
        ),
      );
      connections = SSHConnectionService(
        hostKeyVerifier: HostKeyVerifier(
          findKnownHost: (h, p) async => KnownHost(
            host: h,
            port: p,
            keyType: keyType,
            fingerprint: fingerprint,
            addedAt: DateTime.now(),
          ),
          saveKnownHost: (known) async {},
        ),
      );
    });

    test('opens its own connection and closes it again', () async {
      if (!ready || fingerprint == null) return;
      final handle = await SshSftpOpener(
        connections: connections,
        vault: vault,
      ).open(server);

      expect((await handle.files.home()), isNotEmpty);
      expect(connections.activeSessions, hasLength(1));

      await handle.release();
      expect(connections.activeSessions, isEmpty);
    });

    test('shares a terminal connection and leaves it open', () async {
      if (!ready || fingerprint == null) return;
      final terminal = connections.getOrCreateSession('terminal', server);
      await terminal.connectWith(() => vault.readCredentials(server.id));
      expect(terminal.isConnected, isTrue);

      final handle = await SshSftpOpener(
        connections: connections,
        vault: vault,
      ).open(server, reuse: terminal);
      expect(await handle.files.list(await handle.files.home()), isNotNull);
      // No second connection was made.
      expect(connections.activeSessions, hasLength(1));

      await handle.release();
      expect(
        terminal.isConnected,
        isTrue,
        reason: 'the terminal is not ours to close',
      );
      expect(await terminal.execute('echo still-here'), contains('still-here'));
      await terminal.disconnect();
    });
  });
}
