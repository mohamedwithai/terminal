import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/app.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/screens/server_form_screen.dart';
import 'package:ssh_app/services/vault_service.dart';

import 'support/memory_stores.dart';

const _insecureBanner = 'Secure storage needs HTTPS. Saving is disabled.';

/// Metadata store that fails before the vault writes anything, with an
/// error type the vault does not translate.
class _BrokenMetadataStore extends MemoryMetadataStore {
  @override
  Future<ServerConfig?> getServer(String id) async {
    throw StateError('Box has already been closed.');
  }
}

void main() {
  Future<void> pumpApp(
    WidgetTester tester,
    VaultService vault, {
    bool secureStorageAvailable = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultServiceProvider.overrideWithValue(vault),
          secureStorageAvailableProvider.overrideWithValue(
            secureStorageAvailable,
          ),
        ],
        child: const SshApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openAddForm(WidgetTester tester) async {
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.byType(ServerFormScreen), findsOneWidget);
  }

  Future<void> fillPasswordServer(WidgetTester tester) async {
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Build box');
    await tester.enterText(
      find.widgetWithText(TextField, 'Host'),
      'example.com',
    );
    await tester.enterText(find.widgetWithText(TextField, 'Username'), 'ada');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pw');
  }

  TextButton saveButton(WidgetTester tester) {
    return tester.widget<TextButton>(find.widgetWithText(TextButton, 'Save'));
  }

  testWidgets(
    'a failing SecureStore keeps the form open and shows a SnackBar',
    (tester) async {
      final metadata = MemoryMetadataStore();
      final vault = VaultService(
        secureStore: FailingSecureStore(
          PlatformException(code: 'write', message: 'Keystore is locked.'),
        ),
        metadataStore: metadata,
      );
      await pumpApp(tester, vault);
      await openAddForm(tester);
      await fillPasswordServer(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.byType(ServerFormScreen), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.textContaining(
            'Could not save the credentials to secure storage.',
          ),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Keystore is locked.'), findsOneWidget);
      expect(saveButton(tester).onPressed, isNotNull);
      expect(find.text('Build box'), findsOneWidget);
      expect(metadata.servers, isEmpty);
    },
  );

  testWidgets('an error the vault does not translate still shows a SnackBar', (
    tester,
  ) async {
    final vault = VaultService(
      secureStore: MemorySecureStore(),
      metadataStore: _BrokenMetadataStore(),
    );
    await pumpApp(tester, vault);
    await openAddForm(tester);
    await fillPasswordServer(tester);

    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.byType(ServerFormScreen), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.textContaining('Could not save the server.'),
      ),
      findsOneWidget,
    );
    expect(saveButton(tester).onPressed, isNotNull);
  });

  testWidgets('without a secure context the list warns and Save is disabled', (
    tester,
  ) async {
    final vault = VaultService(
      secureStore: MemorySecureStore(),
      metadataStore: MemoryMetadataStore(),
    );
    await pumpApp(tester, vault, secureStorageAvailable: false);

    expect(find.text(_insecureBanner), findsOneWidget);

    await openAddForm(tester);
    await fillPasswordServer(tester);
    expect(saveButton(tester).onPressed, isNull);
  });

  testWidgets('a secure context shows no banner', (tester) async {
    final vault = VaultService(
      secureStore: MemorySecureStore(),
      metadataStore: MemoryMetadataStore(),
    );
    await pumpApp(tester, vault);

    expect(find.text(_insecureBanner), findsNothing);
  });
}
