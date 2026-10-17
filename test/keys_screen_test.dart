import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/app.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/screens/keys/key_detail_screen.dart';
import 'package:ssh_app/services/ssh_key_material.dart';
import 'package:ssh_app/services/vault_service.dart';

import 'support/memory_stores.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  late MemorySecureStore secure;
  late MemoryMetadataStore metadata;
  late VaultService vault;
  late List<(String, String)> shared;
  late String? clipboard;
  String? pickedFile;

  /// Builds the stores inside the test body: created in setUp they would
  /// live outside the test's fake-async zone and their futures would never
  /// complete under pump.
  void init() {
    secure = MemorySecureStore();
    metadata = MemoryMetadataStore();
    vault = VaultService(secureStore: secure, metadataStore: metadata);
    shared = [];
    clipboard = null;
    pickedFile = null;
  }

  void ktest(String name, Future<void> Function(WidgetTester tester) body) {
    testWidgets(name, (tester) async {
      init();
      await body(tester);
    });
  }

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultServiceProvider.overrideWithValue(vault),
          keyFilePickerProvider.overrideWithValue(() async => pickedFile),
          shareTextProvider.overrideWithValue((text, subject) async {
            shared.add((text, subject));
          }),
        ],
        child: const SshApp(),
      ),
    );
    await tester.pumpAndSettle();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.tap(find.text('Keys'));
    await tester.pumpAndSettle();
  }

  /// Key generation and bcrypt run in an isolate, in real time.
  Future<void> waitForWork(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(LinearProgressIndicator).evaluate().isEmpty) return;
    }
  }

  ktest('empty state, then generating an Ed25519 key shows its public key', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(find.text('No keys yet'), findsOneWidget);

    await tester.tap(find.text('Add key').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate Ed25519'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Phone');
    await tester.tap(find.widgetWithText(FilledButton, 'Generate'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await waitForWork(tester);
    await tester.pumpAndSettle();

    expect(find.textContaining('Key saved'), findsOneWidget);
    final publicKey = tester
        .widget<SelectableText>(
          find.descendant(
            of: find.byKey(const ValueKey('public-key')),
            matching: find.byType(SelectableText),
          ),
        )
        .data!;
    expect(publicKey, startsWith('ssh-ed25519 AAAA'));
    expect(publicKey, endsWith(' Phone'));
    final record = (await vault.listKeys()).single;
    expect(record.publicKey, publicKey);
    expect(record.encrypted, isFalse);
    expect(find.text(record.fingerprint), findsOneWidget);

    // Copy and share give the same single line.
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('public-key')),
        matching: find.text('Copy'),
      ),
    );
    await tester.pump();
    expect(clipboard, publicKey);
    await tester.tap(find.text('Share'));
    await tester.pump();
    expect(shared, [(publicKey, 'Phone')]);
  });

  ktest('a passphrase must be confirmed, then encrypts the key', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.text('Add key').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate Ed25519'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Passphrase (optional)'),
      'hunter2',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Confirm passphrase'),
      'hunter3',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Generate'));
    await tester.pumpAndSettle();
    expect(find.text('The passphrases do not match.'), findsOneWidget);
    expect(await vault.listKeys(), isEmpty);

    await tester.enterText(
      find.widgetWithText(TextField, 'Confirm passphrase'),
      'hunter2',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Generate'));
    await tester.pump();
    await waitForWork(tester);
    await tester.pumpAndSettle();

    final record = (await vault.listKeys()).single;
    expect(record.name, 'My Ed25519 key');
    expect(record.encrypted, isTrue);
    expect((await vault.readKeyMaterial(record.id)).passphrase, 'hunter2');
    expect(find.text('Protected'), findsOneWidget);
  });

  ktest('importing a key file shows the same fingerprint as ssh-keygen', (
    tester,
  ) async {
    pickedFile = fixture('id_ed25519');
    await pumpApp(tester);
    await tester.tap(find.text('Add key').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from a file'));
    await tester.pumpAndSettle();
    expect(find.textContaining('BEGIN OPENSSH PRIVATE KEY'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pump();
    await waitForWork(tester);
    await tester.pumpAndSettle();

    expect(
      find.text('SHA256:4k5ZZIUZsqSTfrwC1i37PlLMgG5qosKN5ZA6aci6E/w'),
      findsOneWidget,
    );
    expect((await vault.listKeys()).single.name, 'Imported key');
  });

  ktest('an encrypted key asks for its passphrase and rejects a wrong one', (
    tester,
  ) async {
    final key = generateKey(KeyAlgorithm.ed25519, passphrase: 'right');
    pickedFile = key.privateKey;
    await pumpApp(tester);
    await tester.tap(find.text('Add key').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from a file'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pump();
    await waitForWork(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter its passphrase'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Passphrase'),
      'wrong',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pump();
    await waitForWork(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('Check the passphrase'), findsOneWidget);
    expect(await vault.listKeys(), isEmpty);

    await tester.enterText(
      find.widgetWithText(TextField, 'Passphrase'),
      'right',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pump();
    await waitForWork(tester);
    await tester.pumpAndSettle();
    expect((await vault.listKeys()).single.encrypted, isTrue);
  });

  ktest('something that is not a key is refused without being saved', (
    tester,
  ) async {
    pickedFile = 'hello, this is not a key';
    await pumpApp(tester);
    await tester.tap(find.text('Add key').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from a file'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pump();
    await waitForWork(tester);
    await tester.pumpAndSettle();

    expect(find.textContaining('not a valid OpenSSH or PEM'), findsOneWidget);
    expect(await vault.listKeys(), isEmpty);
    expect(secure.values, isEmpty);
  });

  ktest('the host form picks a saved key and does not hold its text', (
    tester,
  ) async {
    final key = generateKey(KeyAlgorithm.ed25519);
    final record = await vault.addKey(
      name: 'Phone',
      privateKey: key.privateKey,
      info: key.info,
    );
    await pumpApp(tester);
    await tester.tap(find.text('Hosts'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FloatingActionButton, 'New host'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Build box');
    await tester.enterText(
      find.widgetWithText(TextField, 'Host'),
      'example.com',
    );
    await tester.enterText(find.widgetWithText(TextField, 'Username'), 'ada');
    await tester.tap(find.text('Private key'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Private key'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<String?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Phone · Ed25519').last);
    await tester.pumpAndSettle();
    // No private key field while a saved key is chosen.
    expect(find.widgetWithText(TextField, 'Private key'), findsNothing);

    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    final server = (await vault.listServers()).single;
    expect(server.keyId, record.id);
    expect(secure.values[credentialStorageKey(server.id)], '{}');
    expect(
      (await vault.readCredentials(server.id))!.privateKey,
      key.privateKey,
    );
  });

  ktest('a key that a host uses lists the host and cannot be deleted', (
    tester,
  ) async {
    final key = generateKey(KeyAlgorithm.ed25519);
    final record = await vault.addKey(
      name: 'Phone',
      privateKey: key.privateKey,
      info: key.info,
    );
    await vault.saveServer(
      ServerConfig.create(
        id: 's1',
        label: 'Build box',
        host: 'example.com',
        username: 'ada',
        authType: AuthType.privateKey,
      ).copyWith(keyId: record.id),
      const ServerCredentials(),
    );
    await pumpApp(tester);
    await tester.tap(find.text('Phone'));
    await tester.pumpAndSettle();

    expect(find.text('Build box'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Delete key'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(KeyDetailScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('Delete key'));
    await tester.pumpAndSettle();
    expect(find.textContaining('is used by 1 host'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Delete'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await vault.listKeys(), hasLength(1));
  });

  ktest('an unused key can be deleted', (tester) async {
    final key = generateKey(KeyAlgorithm.ed25519);
    final record = await vault.addKey(
      name: 'Spare',
      privateKey: key.privateKey,
      info: key.info,
    );
    await pumpApp(tester);
    await tester.tap(find.text('Spare'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Delete key'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(KeyDetailScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('Delete key'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(await vault.listKeys(), isEmpty);
    expect(secure.values.containsKey(keyStorageKey(record.id)), isFalse);
    expect(find.text('No keys yet'), findsOneWidget);
  });

  ktest('starting the app moves a host\'s pasted key into the Keys tab', (
    tester,
  ) async {
    await vault.saveServer(
      ServerConfig.create(
        id: 's1',
        label: 'Old box',
        host: 'example.com',
        username: 'ada',
        authType: AuthType.privateKey,
      ),
      ServerCredentials(privateKey: fixture('id_ed25519')),
    );
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [vaultServiceProvider.overrideWithValue(vault)],
        child: const SshApp(),
      ),
    );
    // The migration reads keys in an isolate, in real time.
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      if (find.text('Old box').evaluate().isNotEmpty) break;
    }
    await tester.tap(find.text('Keys'));
    await tester.pumpAndSettle();

    expect(find.text('Old box key'), findsOneWidget);
    expect((await vault.getServer('s1'))!.keyId, isNotNull);
  });
}
