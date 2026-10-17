import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/app.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/services/vault_service.dart';

import 'support/memory_stores.dart';

void main() {
  testWidgets('tags picked in the host form are saved and filter the list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final vault = VaultService(
      secureStore: MemorySecureStore(),
      metadataStore: MemoryMetadataStore(),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [vaultServiceProvider.overrideWithValue(vault)],
        child: const SshApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FloatingActionButton, 'New host'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Build box');
    await tester.enterText(
      find.widgetWithText(TextField, 'Host'),
      'example.com',
    );
    await tester.enterText(find.widgetWithText(TextField, 'Username'), 'ada');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pw');
    await tester.tap(find.widgetWithText(FilterChip, 'Clients'));
    await tester.pump();

    // A new tag is added to the list and selected.
    await tester.tap(find.widgetWithText(ActionChip, 'Tag'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Work');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, 'Work'))
          .selected,
      isTrue,
    );

    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    expect((await vault.listServers()).single.tags, ['Clients', 'Work']);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Work'));
    await tester.pumpAndSettle();
    expect(find.text('Build box'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Personal'));
    await tester.pumpAndSettle();
    expect(find.text('Build box'), findsNothing);
  });
}
