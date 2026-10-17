import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/providers/sftp_providers.dart';
import 'package:ssh_app/screens/files/sftp_browser_controller.dart';
import 'package:ssh_app/services/sftp/local_temp_file.dart';
import 'package:ssh_app/services/sftp/remote_file_system.dart';

import 'support/fake_remote_files.dart';

void main() {
  final server = ServerConfig.create(
    id: 'srv-1',
    label: 'Build box',
    host: 'example.com',
    username: 'ada',
    authType: AuthType.password,
  );

  group('helpers', () {
    test('paths', () {
      expect(joinRemote('/home/ada', 'a.txt'), '/home/ada/a.txt');
      expect(joinRemote('/', 'etc'), '/etc');
      expect(joinRemote('/home/ada/', 'a'), '/home/ada/a');
      expect(parentRemote('/home/ada/a.txt'), '/home/ada');
      expect(parentRemote('/home'), '/');
      expect(parentRemote('/'), '/');
      expect(parentRemote('/home/ada/'), '/home');
      expect(baseName('/home/ada/a.txt'), 'a.txt');
      expect(baseName('/home/ada/'), 'ada');
    });

    test('breadcrumbs', () {
      expect(breadcrumbs('/').map((c) => c.name), ['/']);
      final crumbs = breadcrumbs('/home/ada/src');
      expect(crumbs.map((c) => c.name), ['/', 'home', 'ada', 'src']);
      expect(crumbs.map((c) => c.path), [
        '/',
        '/home',
        '/home/ada',
        '/home/ada/src',
      ]);
    });

    test('folders come first, then the chosen order', () {
      RemoteEntry file(String n, int size, int day) => RemoteEntry(
        name: n,
        isDirectory: false,
        size: size,
        modified: DateTime.utc(2026, 1, day),
      );
      final entries = [
        file('b.txt', 10, 3),
        file('A.txt', 300, 1),
        const RemoteEntry(name: 'zeta', isDirectory: true),
        file('c.txt', 20, 2),
        const RemoteEntry(name: 'Alpha', isDirectory: true),
      ];

      expect(sortEntries(entries, SortField.name).map((e) => e.name), [
        'Alpha',
        'zeta',
        'A.txt',
        'b.txt',
        'c.txt',
      ]);
      expect(
        sortEntries(
          entries,
          SortField.name,
          descending: true,
        ).map((e) => e.name),
        ['zeta', 'Alpha', 'c.txt', 'b.txt', 'A.txt'],
      );
      expect(
        sortEntries(
          entries,
          SortField.size,
          descending: true,
        ).map((e) => e.name).skip(2),
        ['A.txt', 'c.txt', 'b.txt'],
      );
      expect(
        sortEntries(entries, SortField.modified).map((e) => e.name).skip(2),
        ['A.txt', 'c.txt', 'b.txt'],
      );
    });

    test('sizes and names', () {
      expect(formatSize(0), '0 B');
      expect(formatSize(820), '820 B');
      expect(formatSize(1536), '1.5 KB');
      expect(formatSize(5 * 1024 * 1024), '5.0 MB');
      expect(formatSize(300 * 1024 * 1024), '300 MB');
      expect(nameProblem(''), isNotNull);
      expect(nameProblem('a/b'), isNotNull);
      expect(nameProblem('..'), isNotNull);
      expect(nameProblem('notes.txt'), isNull);
    });
  });

  group('browser controller', () {
    late FakeRemoteFiles fs;
    late FakeSftpOpener opener;
    late List<({String name, List<int> bytes})> saved;
    var saveAnswer = true;

    SftpBrowserController make() {
      return SftpBrowserController(
        opener: opener.call,
        server: server,
        saveDownload: (file, name) async {
          saved.add((name: name, bytes: await file.readAll()));
          return saveAnswer;
        },
      );
    }

    setUp(() {
      fs = FakeRemoteFiles()
        ..addFile(
          '/home/ada/notes.txt',
          'hello world!'.codeUnits,
          at: DateTime.utc(2026, 1, 2),
        )
        ..addFile('/home/ada/src/main.dart', 'main'.codeUnits)
        ..addFolder('/home/ada/empty');
      opener = FakeSftpOpener(fs);
      saved = [];
      saveAnswer = true;
    });

    test('starts in the home folder', () async {
      final c = make();
      await c.start();

      expect(c.status, BrowserStatus.ready);
      expect(c.path, '/home/ada');
      expect(c.entries.map((e) => e.name), ['empty', 'src', 'notes.txt']);
      expect(opener.opened.single.serverId, 'srv-1');
      c.dispose();
    });

    test('a connection problem is reported and can be retried', () async {
      opener.failWith = const RemoteFileException('Host key not trusted yet.');
      final c = make();
      await c.start();
      expect(c.status, BrowserStatus.failed);
      expect(c.error, 'Host key not trusted yet.');

      opener.failWith = null;
      await c.start();
      expect(c.status, BrowserStatus.ready);
      c.dispose();
    });

    test('opens folders, goes up, refreshes', () async {
      final c = make();
      await c.start();

      await c.open('/home/ada/src');
      expect(c.path, '/home/ada/src');
      expect(c.entries.single.name, 'main.dart');
      expect(c.canGoUp, isTrue);

      await c.up();
      expect(c.path, '/home/ada');

      fs.addFile('/home/ada/new.txt', [1]);
      await c.refresh();
      expect(c.entries.map((e) => e.name), contains('new.txt'));
      c.dispose();
    });

    test('a folder that cannot be read leaves you where you were', () async {
      fs.failures['/home/ada/src'] = 'Permission denied.';
      final c = make();
      await c.start();

      await c.open('/home/ada/src');

      expect(c.path, '/home/ada');
      expect(c.takeNotice(), 'Permission denied.');
      expect(c.takeNotice(), isNull, reason: 'shown once');
      c.dispose();
    });

    test('sorting toggles direction on the same field', () async {
      final c = make();
      await c.start();
      c.setSort(SortField.size);
      expect(c.sortField, SortField.size);
      expect(c.descending, isFalse);
      c.setSort(SortField.size);
      expect(c.descending, isTrue);
      c.setSort(SortField.name);
      expect(c.descending, isFalse);
      c.dispose();
    });

    test('new folder, rename and delete reload the listing', () async {
      final c = make();
      await c.start();

      expect(await c.createFolder('docs'), isTrue);
      expect(c.entries.map((e) => e.name), contains('docs'));

      final notes = c.entries.firstWhere((e) => e.name == 'notes.txt');
      expect(await c.rename(notes, 'todo.txt'), isTrue);
      expect(c.entries.map((e) => e.name), contains('todo.txt'));
      expect(c.entries.map((e) => e.name), isNot(contains('notes.txt')));

      final src = c.entries.firstWhere((e) => e.name == 'src');
      expect(await c.countInside(src), 1);
      expect(await c.delete(src), isTrue);
      expect(c.entries.map((e) => e.name), isNot(contains('src')));
      expect(fs.files.keys, isNot(contains('/home/ada/src/main.dart')));
      c.dispose();
    });

    test('a failed operation becomes a notice, not a crash', () async {
      fs.failures['/home/ada/notes.txt'] = 'Permission denied.';
      final c = make();
      await c.start();
      final notes = c.entries.firstWhere((e) => e.name == 'notes.txt');

      expect(await c.delete(notes), isFalse);
      expect(c.takeNotice(), 'Permission denied.');
      c.dispose();
    });

    test(
      'a download is saved with its bytes, and the scratch file is removed',
      () async {
        final c = make();
        await c.start();
        final notes = c.entries.firstWhere((e) => e.name == 'notes.txt');

        final transfer = c.download(notes);
        await _until(() => transfer.status != TransferStatus.running);

        expect(transfer.status, TransferStatus.done);
        expect(transfer.bytes, 12);
        expect(transfer.total, 12);
        expect(transfer.fraction, 1.0);
        expect(saved.single.name, 'notes.txt');
        expect(String.fromCharCodes(saved.single.bytes), 'hello world!');
        c.dispose();
      },
    );

    test('declining the save dialog is not a failure', () async {
      saveAnswer = false;
      final c = make();
      await c.start();
      final transfer = c.download(
        c.entries.firstWhere((e) => e.name == 'notes.txt'),
      );
      await _until(() => transfer.status != TransferStatus.running);

      expect(transfer.status, TransferStatus.cancelled);
      expect(transfer.message, 'Not saved');
      c.dispose();
    });

    test('cancelling a download stops it and saves nothing', () async {
      fs.hold = Completer<void>();
      final c = make();
      await c.start();
      final transfer = c.download(
        c.entries.firstWhere((e) => e.name == 'notes.txt'),
      );
      await _until(() => transfer.bytes > 0);
      expect(transfer.status, TransferStatus.running);

      c.cancelTransfer(transfer);
      expect(
        transfer.status,
        TransferStatus.cancelled,
        reason: 'shows at once',
      );
      fs.hold!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(saved, isEmpty);
      expect(transfer.status, TransferStatus.cancelled);
      c.dispose();
    });

    test('a download that fails says why', () async {
      fs.failures['/home/ada/notes.txt'] = 'Permission denied.';
      final c = make();
      await c.start();
      final transfer = c.download(
        c.entries.firstWhere((e) => e.name == 'notes.txt'),
      );
      await _until(() => transfer.status != TransferStatus.running);

      expect(transfer.status, TransferStatus.failed);
      expect(transfer.message, 'Permission denied.');
      expect(saved, isEmpty);
      c.dispose();
    });

    UploadFile upload(String name, String text) => UploadFile(
      name: name,
      length: text.length,
      open: () => Stream.fromIterable([
        for (var i = 0; i < text.length; i += 3)
          Uint8List.fromList(
            text
                .substring(i, i + 3 > text.length ? text.length : i + 3)
                .codeUnits,
          ),
      ]),
    );

    test('uploads go to the current folder and show up', () async {
      final c = make();
      await c.start();

      await c.upload([
        upload('a.txt', 'first file'),
        upload('b.txt', 'second'),
      ]);

      expect(String.fromCharCodes(fs.files['/home/ada/a.txt']!), 'first file');
      expect(String.fromCharCodes(fs.files['/home/ada/b.txt']!), 'second');
      expect(c.entries.map((e) => e.name), containsAll(['a.txt', 'b.txt']));
      expect(
        c.transfers.map((t) => t.status),
        everyElement(TransferStatus.done),
      );
      expect(c.transfers.first.isUpload, isTrue);
      c.dispose();
    });

    test('cancelling an upload stops it', () async {
      fs.hold = Completer<void>();
      final c = make();
      await c.start();
      final done = c.upload([upload('big.bin', 'x' * 30)]);
      await _until(() => c.transfers.isNotEmpty && c.transfers.first.bytes > 0);

      c.cancelTransfer(c.transfers.first);
      fs.hold!.complete();
      await done;

      expect(c.transfers.single.status, TransferStatus.cancelled);
      expect(fs.files.containsKey('/home/ada/big.bin'), isFalse);
      c.dispose();
    });

    test('a failed upload is reported and the next file still goes', () async {
      fs.failures['/home/ada/locked.txt'] = 'Permission denied.';
      final c = make();
      await c.start();

      await c.upload([upload('locked.txt', 'no'), upload('fine.txt', 'yes')]);

      final byName = {for (final t in c.transfers) t.name: t};
      expect(byName['locked.txt']!.status, TransferStatus.failed);
      expect(byName['locked.txt']!.message, 'Permission denied.');
      expect(byName['fine.txt']!.status, TransferStatus.done);
      c.dispose();
    });

    test('finished transfers can be dismissed; running ones cannot', () async {
      fs.hold = Completer<void>();
      final c = make();
      await c.start();
      final done = c.upload([upload('a.txt', 'x' * 30)]);
      await _until(() => c.transfers.isNotEmpty && c.transfers.first.bytes > 0);
      final running = c.transfers.first;
      expect(c.hasRunningTransfer, isTrue);

      c.dismissTransfer(running);
      expect(c.transfers, contains(running));

      fs.hold!.complete();
      await done;
      c.dismissTransfer(running);
      expect(c.transfers, isEmpty);
      c.dispose();
    });

    test('leaving cancels transfers and lets go of the connection', () async {
      fs.hold = Completer<void>();
      final c = make();
      await c.start();
      final transfer = c.download(
        c.entries.firstWhere((e) => e.name == 'notes.txt'),
      );
      await _until(() => transfer.bytes > 0);

      c.dispose();
      fs.hold!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(transfer.cancel.isCancelled, isTrue);
      expect(opener.released, 1);
      expect(saved, isEmpty);
    });
  });

  test('a scratch file keeps only the last part of a remote name', () async {
    final file = await LocalTempFile.create('../../etc/passwd');
    await file.add(Uint8List.fromList([1, 2, 3]));
    await file.close();

    // One file, directly in its own scratch folder.
    final segments = file.path.split('/');
    expect(segments.last, '.._.._etc_passwd');
    expect(segments[segments.length - 2], startsWith('ssh_download_'));
    expect(await file.length(), 3);
    expect(await file.readAll(), [1, 2, 3]);
    await file.delete();

    // These names would otherwise mean a folder.
    for (final name in ['..', '.', '']) {
      final odd = await LocalTempFile.create(name);
      await odd.add(Uint8List.fromList([9]));
      await odd.close();
      expect(odd.path.split('/').last, 'file');
      expect(await odd.length(), 1);
      await odd.delete();
    }
  });
}

/// Waits (in real time) until [condition] holds.
Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue, reason: 'timed out waiting');
}
