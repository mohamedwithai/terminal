import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/app.dart';
import 'package:ssh_app/models/app_settings.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/providers/ssh_providers.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/screens/format.dart';
import 'package:ssh_app/screens/terminal/connection_card.dart';
import 'package:ssh_app/screens/terminal/host_key_sheet.dart';
import 'package:ssh_app/services/ssh/pausable_deadline.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';
import 'package:ssh_app/services/ssh/ssh_errors.dart';
import 'package:ssh_app/services/vault_service.dart';
import 'package:ssh_app/theme/terminal_themes.dart';
import 'package:ssh_app/theme/tokens.dart';
import 'package:ssh_app/models/server_credentials.dart';

import 'support/memory_stores.dart';

void main() {
  final server = ServerConfig.create(
    id: 'srv-1',
    label: 'Build box',
    host: 'example.com',
    username: 'ada',
    authType: AuthType.password,
    now: DateTime.utc(2026, 5, 1),
  );

  group('host key sheet helpers', () {
    test('fingerprints are grouped in fours without the algorithm', () {
      expect(
        groupFingerprint('SHA256:Q0ynKtbgRmoAoNdX'),
        'Q0yn Ktbg RmoA oNdX',
      );
      expect(groupFingerprint('SHA256:abcdef'), 'abcd ef');
      expect(fingerprintAlgorithm('SHA256:abc'), 'SHA256');
    });

    test('the check command matches the key type', () {
      expect(
        hostKeyCheckCommand('ssh-ed25519'),
        'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub',
      );
      expect(hostKeyCheckCommand('ecdsa-sha2-nistp256'), contains('ecdsa'));
      expect(hostKeyCheckCommand('ssh-rsa'), contains('_rsa_'));
      expect(hostKeyCheckCommand('something-else'), contains('ssh_host_*'));
    });
  });

  test('errors become one plain sentence', () {
    expect(
      plainConnectionError(const SSHDnsException('x'), server),
      "Couldn't find example.com. Check the host name.",
    );
    expect(
      plainConnectionError(const SSHConnectionRefusedException('x'), server),
      'example.com refused the connection on port 22.',
    );
    expect(
      plainConnectionError(const SSHAuthFailedException('x'), server),
      contains('ada'),
    );
    expect(plainConnectionError(null, server, fallback: 'Boom'), 'Boom');
  });

  group('connection card model', () {
    test('connecting highlights the current of five steps', () {
      final model = ConnectionCardModel.from(
        state: const SSHConnectionState.connecting(
          SSHConnectionStage.exchangingKeys,
        ),
        server: server,
      );
      expect(connectionSteps, hasLength(5));
      expect(model.step, 2);
      expect(model.failed, isFalse);
    });

    test('an error marks the failed step', () {
      final model = ConnectionCardModel.from(
        state: const SSHConnectionState.error(
          'raw text',
          SSHTimeoutException('t'),
          SSHConnectionStage.authenticating,
        ),
        server: server,
      );
      expect(model.failed, isTrue);
      expect(model.step, 4);
      expect(model.message, "example.com didn't answer in time.");
    });

    testWidgets('failed card offers Edit host and Retry, not Cancel', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConnectionCard(
              model: ConnectionCardModel.from(
                state: const SSHConnectionState.error('x'),
                server: server,
              ),
              onCancel: () {},
              onDetails: () {},
              onRetry: () {},
              onEditHost: () {},
            ),
          ),
        ),
      );
      expect(find.text('Edit host'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Cancel'), findsNothing);
      expect(find.text('Details'), findsOneWidget);
    });
  });

  group('PausableDeadline', () {
    testWidgets('expires, but not while paused', (tester) async {
      final deadline = PausableDeadline(const Duration(seconds: 2));
      addTearDown(deadline.cancel);
      var expired = false;
      deadline.expired.then((_) => expired = true);

      await tester.pump(const Duration(seconds: 1));
      deadline.pause();
      await tester.pump(const Duration(seconds: 30));
      expect(expired, isFalse);

      deadline.resume();
      await tester.pump(const Duration(milliseconds: 900));
      expect(expired, isFalse);
      await tester.pump(const Duration(milliseconds: 300));
      expect(expired, isTrue);
    });
  });

  group('models', () {
    test('settings round-trip and ignore junk', () {
      final settings = const AppSettings().copyWith(
        terminalTheme: TerminalThemeId.dracula,
        cursor: CursorShape.bar,
        hostFontSizes: {'a': 18},
        volumeKeys: true,
      );
      final copy = AppSettings.fromJson(settings.toJson());
      expect(copy.terminalTheme, TerminalThemeId.dracula);
      expect(copy.cursor, CursorShape.bar);
      expect(copy.fontSizeFor('a'), 18);
      expect(copy.fontSizeFor('b'), AppSettings.defaultFontSize);
      expect(copy.volumeKeys, isTrue);

      final junk = AppSettings.fromJson({
        'terminalTheme': 'nope',
        'fontSize': 500,
        'tags': [1, ' Work ', ''],
      });
      expect(junk.terminalTheme, TerminalThemeId.ink);
      expect(junk.fontSize, AppSettings.maxFontSize);
      expect(junk.tags, ['Work']);
    });

    test('server tags and last connected survive JSON; old records load', () {
      final at = DateTime.utc(2026, 6, 1, 12);
      final tagged = server.copyWith(tags: ['Clients'], lastConnectedAt: at);
      expect(ServerConfig.fromJson(tagged.toJson()), tagged);

      final old = server.toJson()
        ..remove('tags')
        ..remove('lastConnectedAt');
      final loaded = ServerConfig.fromJson(old);
      expect(loaded.tags, isEmpty);
      expect(loaded.lastConnectedAt, isNull);
    });

    test('avatar colors are stable per host', () {
      expect(
        AppColors.avatarColorFor('srv-1'),
        AppColors.avatarColorFor('srv-1'),
      );
    });

    test('relative times', () {
      final now = DateTime.utc(2026, 6, 10, 12);
      expect(formatRelativeTime(now, now), 'just now');
      expect(
        formatRelativeTime(now.subtract(const Duration(minutes: 5)), now),
        '5m ago',
      );
      expect(
        formatRelativeTime(now.subtract(const Duration(hours: 3)), now),
        '3h ago',
      );
      expect(
        formatRelativeTime(now.subtract(const Duration(days: 2)), now),
        '2d ago',
      );
    });
  });

  group('hosts screen', () {
    Future<VaultService> seed() async {
      final vault = VaultService(
        secureStore: MemorySecureStore(),
        metadataStore: MemoryMetadataStore(),
      );
      for (final (id, label, tag) in [
        ('1', 'Alpha', 'Personal'),
        ('2', 'Bravo', 'Clients'),
      ]) {
        await vault.saveServer(
          server.copyWith(id: id, label: label, tags: [tag]),
          const ServerCredentials(password: 'p'),
        );
      }
      await vault.recordConnected('1', DateTime.utc(2026, 6, 10, 9));
      return vault;
    }

    testWidgets('search and tag chips filter; last connected shows', (
      tester,
    ) async {
      final vault = await seed();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            vaultServiceProvider.overrideWithValue(vault),
            clockProvider.overrideWithValue(
              () => DateTime.utc(2026, 6, 10, 12),
            ),
          ],
          child: const SshApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Bravo'), findsOneWidget);
      expect(find.textContaining('Last connected 3h ago'), findsOneWidget);
      expect(find.textContaining('Never connected'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Clients'));
      await tester.pumpAndSettle();
      expect(find.text('Alpha'), findsNothing);
      expect(find.text('Bravo'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
      await tester.enterText(find.byType(TextField), 'alp');
      await tester.pumpAndSettle();
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Bravo'), findsNothing);
    });

    testWidgets('bottom navigation switches tabs', (tester) async {
      final vault = await seed();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [vaultServiceProvider.overrideWithValue(vault)],
          child: const SshApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Files'));
      await tester.pumpAndSettle();
      expect(
        find.text('Browse, upload and download files over SFTP.'),
        findsOneWidget,
      );
    });
  });
}
