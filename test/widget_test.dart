import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/app.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/services/vault_service.dart';

import 'support/memory_stores.dart';

void main() {
  testWidgets('empty vault shows the empty state', (tester) async {
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

    expect(find.text('No hosts yet'), findsOneWidget);
    expect(find.text('New host'), findsWidgets);
  });

  testWidgets('server list shows the label and hides the password', (
    tester,
  ) async {
    final vault = VaultService(
      secureStore: MemorySecureStore(),
      metadataStore: MemoryMetadataStore(),
    );
    await vault.saveServer(
      ServerConfig.create(
        id: 'ui-1',
        label: 'Build box',
        host: 'example.com',
        username: 'ada',
        authType: AuthType.password,
        now: DateTime.utc(2026, 5, 1),
      ),
      const ServerCredentials(password: 'super-secret-password'),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [vaultServiceProvider.overrideWithValue(vault)],
        child: const SshApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Build box'), findsOneWidget);
    expect(find.text('ada@example.com'), findsOneWidget);
    expect(find.text('super-secret-password'), findsNothing);
    expect(find.textContaining('Never connected'), findsOneWidget);
  });
}
