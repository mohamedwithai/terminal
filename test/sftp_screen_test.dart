import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/app.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/providers/session_tabs_providers.dart';
import 'package:ssh_app/providers/sftp_providers.dart';
import 'package:ssh_app/providers/ssh_providers.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/screens/files/sftp_browser_screen.dart';
import 'package:ssh_app/services/sftp/local_temp_file.dart';
import 'package:ssh_app/services/sftp/remote_file_system.dart';
import 'package:ssh_app/services/vault_service.dart';

import 'support/fake_remote_files.dart';
import 'support/fake_terminal_session.dart';
import 'support/memory_stores.dart';

void main() {
  final server = ServerConfig.create(
    id: 'srv-1',
    label: 'Build box',
    host: 'example.com',
    username: 'ada',
    authType: AuthType.password,
  );

  late FakeRemoteFiles fs;
  late FakeSftpOpener opener;
  late List<String> saved;
  late List<UploadFile> pick;

  setUp(() {
    fs = FakeRemoteFiles()
      ..addFile(
        '/home/ada/notes.txt',
        'hello world!'.codeUnits,
        at: DateTime.utc(2026, 1, 2, 9, 30),
      )
      ..addFile('/home/ada/big.log', List.filled(2048, 1))
      ..addFile('/home/ada/src/main.dart', 'main'.codeUnits)
      ..addFile('/home/ada/src/util.dart', 'util'.codeUnits)
      ..addFolder('/home/ada/empty');
    opener = FakeSftpOpener(fs);
    saved = [];
    pick = [];
  });

  Future<void> pumpBrowser(WidgetTester tester, {bool pushed = false}) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final browser = SftpBrowserScreen(server: server);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          sftpOpenerProvider.overrideWithValue(opener.call),
          fileSaverProvider.overrideWithValue((
            LocalTempFile file,
            String name,
          ) async {
            saved.add('$name:${(await file.readAll()).length}');
            return true;
          }),
          uploadPickerProvider.overrideWithValue(() async => pick),
        ],
        child: MaterialApp(
          home: pushed
              ? Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => Navigator.of(
                        context,
                      ).push(MaterialPageRoute<void>(builder: (_) => browser)),
                      child: const Text('Open files'),
                    ),
                  ),
                )
              : browser,
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (pushed) {
      await tester.tap(find.text('Open files'));
      await tester.pumpAndSettle();
    }
  }

  /// Real file IO for downloads takes real time.
  Future<void> ioWork(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 25));
    }
  }

  Future<void> options(WidgetTester tester, String name) async {
    await tester.tap(find.byTooltip('Options for $name'));
    await tester.pumpAndSettle();
  }

  List<String> names(WidgetTester tester) => [
    for (final w in tester.widgetList<ListTile>(find.byType(ListTile)))
      if (w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('entry-'))
        (w.key! as ValueKey<String>).value.substring('entry-'.length),
  ];

  testWidgets('shows the home folder, folders first, with a path trail', (
    tester,
  ) async {
    await pumpBrowser(tester);

    expect(names(tester), ['empty', 'src', 'big.log', 'notes.txt']);
    expect(find.text('ada'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);
    expect(find.textContaining('12 B'), findsOneWidget);
    expect(opener.opened.single.reused, isFalse);
  });

  testWidgets('tap a folder to open it; the trail and Up go back', (
    tester,
  ) async {
    await pumpBrowser(tester);

    await tester.tap(find.byKey(const ValueKey('entry-src')));
    await tester.pumpAndSettle();
    expect(names(tester), ['main.dart', 'util.dart']);
    expect(find.byKey(const ValueKey('crumb-/home/ada/src')), findsOneWidget);

    await tester.tap(find.byTooltip('Up one folder'));
    await tester.pumpAndSettle();
    expect(names(tester), contains('notes.txt'));

    await tester.tap(find.byKey(const ValueKey('entry-src')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('crumb-/home')));
    await tester.pumpAndSettle();
    expect(names(tester), ['ada']);
  });

  testWidgets('the system back button goes up a folder, then leaves', (
    tester,
  ) async {
    await pumpBrowser(tester, pushed: true);

    await tester.tap(find.byKey(const ValueKey('entry-src')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SftpBrowserScreen), findsOneWidget);
    expect(names(tester), contains('notes.txt'));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    // At /home/ada the screen can still go up to /home and /.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SftpBrowserScreen), findsNothing);
    expect(opener.released, 1);
  });

  testWidgets('an empty folder says so', (tester) async {
    await pumpBrowser(tester);
    await tester.tap(find.byKey(const ValueKey('entry-empty')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('files-empty')), findsOneWidget);
  });

  testWidgets('sorting by size, and again to reverse', (tester) async {
    await pumpBrowser(tester);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sort by size'));
    await tester.pumpAndSettle();
    expect(names(tester), ['empty', 'src', 'notes.txt', 'big.log']);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sort by size'));
    await tester.pumpAndSettle();
    expect(names(tester), ['empty', 'src', 'big.log', 'notes.txt']);
  });

  testWidgets('a connection problem shows a message and Try again', (
    tester,
  ) async {
    opener.failWith = const RemoteFileException('Host key not trusted yet.');
    await pumpBrowser(tester);

    expect(find.byKey(const ValueKey('files-error')), findsOneWidget);
    expect(find.text('Host key not trusted yet.'), findsOneWidget);

    opener.failWith = null;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(names(tester), contains('notes.txt'));
  });

  testWidgets('new folder: a taken name is refused in place', (tester) async {
    await pumpBrowser(tester);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New folder'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'src');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('already something called "src"'),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField), 'a/b');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(find.text('A name cannot contain "/".'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'docs');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(fs.folders, contains('/home/ada/docs'));
    expect(names(tester), contains('docs'));
  });

  testWidgets('rename', (tester) async {
    await pumpBrowser(tester);
    await options(tester, 'notes.txt');
    expect(find.textContaining('rw-r--r--'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('action-rename')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'big.log');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(find.textContaining('already something called'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'todo.txt');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(names(tester), contains('todo.txt'));
    expect(names(tester), isNot(contains('notes.txt')));
    expect(fs.files.containsKey('/home/ada/todo.txt'), isTrue);
  });

  testWidgets('deleting a folder says what is inside, and asks first', (
    tester,
  ) async {
    await pumpBrowser(tester);
    await options(tester, 'src');
    await tester.tap(find.byKey(const ValueKey('action-delete')));
    await tester.pumpAndSettle();
    expect(find.textContaining('and the 2 items inside it'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(fs.files.keys, contains('/home/ada/src/main.dart'));

    await options(tester, 'src');
    await tester.tap(find.byKey(const ValueKey('action-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(names(tester), isNot(contains('src')));
    expect(fs.files.keys, isNot(contains('/home/ada/src/main.dart')));
  });

  testWidgets('deleting a file asks first', (tester) async {
    await pumpBrowser(tester);
    await options(tester, 'notes.txt');
    await tester.tap(find.byKey(const ValueKey('action-delete')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Delete "notes.txt" from Build box'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(fs.files.containsKey('/home/ada/notes.txt'), isFalse);
  });

  testWidgets('a failed delete shows the reason', (tester) async {
    fs.failures['/home/ada/notes.txt'] = 'Permission denied.';
    await pumpBrowser(tester);
    await options(tester, 'notes.txt');
    await tester.tap(find.byKey(const ValueKey('action-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Permission denied.'), findsOneWidget);
    expect(names(tester), contains('notes.txt'));
  });

  testWidgets('download shows progress, then Saved; folders have no download', (
    tester,
  ) async {
    await pumpBrowser(tester);
    await options(tester, 'src');
    expect(find.byKey(const ValueKey('action-download')), findsNothing);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await options(tester, 'notes.txt');
    await tester.tap(find.byKey(const ValueKey('action-download')));
    await tester.pump();
    await ioWork(tester);

    expect(saved, ['notes.txt:12']);
    expect(find.text('Saved'), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();
    expect(find.text('Saved'), findsNothing);
  });

  testWidgets('a running download can be cancelled', (tester) async {
    fs.hold = null;
    await pumpBrowser(tester);
    final gate = fs.hold = Completerless();
    await options(tester, 'big.log');
    await tester.tap(find.byKey(const ValueKey('action-download')));
    await tester.pump();
    await ioWork(tester);
    expect(find.byTooltip('Cancel'), findsOneWidget);
    expect(find.textContaining('Downloading'), findsOneWidget);

    await tester.tap(find.byTooltip('Cancel'));
    await tester.pump();
    expect(find.text('Cancelled'), findsOneWidget);
    gate.complete();
    await ioWork(tester);
    expect(saved, isEmpty);
  });

  testWidgets('upload: replacing an existing file is confirmed', (
    tester,
  ) async {
    Stream<Uint8List> bytes(String text) =>
        Stream.value(Uint8List.fromList(text.codeUnits));
    pick = [
      UploadFile(name: 'notes.txt', length: 3, open: () => bytes('new')),
      UploadFile(name: 'fresh.txt', length: 5, open: () => bytes('fresh')),
    ];
    await pumpBrowser(tester);

    await tester.tap(find.text('Upload'));
    await tester.pumpAndSettle();
    expect(find.text('Replace this file?'), findsOneWidget);
    expect(find.textContaining('notes.txt already exists'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
      String.fromCharCodes(fs.files['/home/ada/notes.txt']!),
      'hello world!',
    );
    expect(fs.files.containsKey('/home/ada/fresh.txt'), isFalse);

    await tester.tap(find.text('Upload'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();
    expect(String.fromCharCodes(fs.files['/home/ada/notes.txt']!), 'new');
    expect(String.fromCharCodes(fs.files['/home/ada/fresh.txt']!), 'fresh');
    expect(find.text('Uploaded'), findsNWidgets(2));
    expect(names(tester), contains('fresh.txt'));
  });

  testWidgets('choosing no file uploads nothing', (tester) async {
    await pumpBrowser(tester);
    await tester.tap(find.text('Upload'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(fs.calls.where((c) => c.startsWith('upload')), isEmpty);
  });

  testWidgets('leaving with a transfer running asks first', (tester) async {
    await pumpBrowser(tester, pushed: true);
    Stream<Uint8List> slow() =>
        Stream.value(Uint8List.fromList(List.filled(40, 1)));
    pick = [UploadFile(name: 'a.bin', length: 40, open: slow)];
    final gate = fs.hold = Completerless();
    await tester.tap(find.text('Upload'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Back first goes up through /home and /, then asks.
    for (var i = 0; i < 3; i++) {
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }
    expect(find.text('Transfers are still running'), findsOneWidget);
    await tester.tap(find.text('Stay'));
    await tester.pumpAndSettle();
    expect(find.byType(SftpBrowserScreen), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
  });

  group('Files tab', () {
    late MultiSessionService service;

    Future<void> pumpApp(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      service = MultiSessionService();
      final vault = VaultService(
        secureStore: MemorySecureStore(),
        metadataStore: MemoryMetadataStore(),
      );
      await vault.saveServer(server, const ServerCredentials(password: 'pw'));
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            vaultServiceProvider.overrideWithValue(vault),
            sshConnectionServiceProvider.overrideWithValue(service),
            sftpOpenerProvider.overrideWithValue(opener.call),
            fileSaverProvider.overrideWithValue((file, name) async => true),
            // An open terminal tab must not really connect.
            sshSessionStateProvider.overrideWith(
              (ref, args) => const Stream.empty(),
            ),
            sshSessionControllerProvider.overrideWith((ref, args) {
              return _IdleController(
                ref: ref,
                sessionId: args.sessionId,
                server: args.server,
              );
            }),
          ],
          child: const SshApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Files'));
      await tester.pumpAndSettle();
    }

    testWidgets('lists hosts and opens the browser over its own connection', (
      tester,
    ) async {
      await pumpApp(tester);
      expect(find.text('Build box'), findsOneWidget);
      expect(find.text('ada@example.com'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('files-host-srv-1')));
      await tester.pumpAndSettle();

      expect(find.byType(SftpBrowserScreen), findsOneWidget);
      expect(opener.opened.single.reused, isFalse);
      expect(names(tester), contains('notes.txt'));
    });

    testWidgets('a host with an open terminal shares that connection', (
      tester,
    ) async {
      await pumpApp(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SshApp)),
      );
      container.read(sessionTabsProvider.notifier).open(server);
      container.read(sessionTabsProvider.notifier).hide();
      await tester.pump();
      await tester.pump();

      expect(find.text('Uses your open session'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('files-host-srv-1')));
      await tester.pumpAndSettle();

      expect(opener.opened.single.reused, isTrue);
    });
  });
}

class _IdleController extends SSHSessionController {
  _IdleController({
    required super.ref,
    required super.sessionId,
    required super.server,
  });

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}
}

/// A gate a test opens when it wants the held transfer to go on.
class Completerless extends _Gate {}

class _Gate implements Completer<void> {
  final _inner = Completer<void>();

  @override
  Future<void> get future => _inner.future;

  @override
  bool get isCompleted => _inner.isCompleted;

  @override
  void complete([FutureOr<void>? value]) {
    if (!_inner.isCompleted) _inner.complete(value);
  }

  @override
  void completeError(Object error, [StackTrace? stackTrace]) =>
      _inner.completeError(error, stackTrace);
}
