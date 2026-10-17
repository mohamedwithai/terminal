import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/models/app_settings.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/providers/preferences_providers.dart';
import 'package:ssh_app/providers/ssh_providers.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/screens/home_screen.dart';
import 'package:ssh_app/screens/settings_screen.dart';
import 'package:ssh_app/screens/terminal/connection_card.dart';
import 'package:ssh_app/screens/terminal/host_key_sheet.dart';
import 'package:ssh_app/screens/terminal_keyboard_bar.dart';
import 'package:ssh_app/services/preferences_store.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';
import 'package:ssh_app/services/ssh/ssh_errors.dart';
import 'package:ssh_app/services/ssh_key_material.dart';
import 'package:ssh_app/services/vault_service.dart';
import 'package:ssh_app/theme/terminal_themes.dart';

import 'dart:async';

import 'package:ssh_app/theme/app_theme.dart';

import 'support/memory_stores.dart';

/// Loads the bundled fonts so goldens show the real typography.
Future<void> loadFonts() async {
  const families = {
    'IBMPlexSans': [
      'IBMPlexSans-Regular.ttf',
      'IBMPlexSans-Medium.ttf',
      'IBMPlexSans-SemiBold.ttf',
      'IBMPlexSans-Bold.ttf',
    ],
    'JetBrainsMono': ['JetBrainsMono-Regular.ttf', 'JetBrainsMono-Bold.ttf'],
    'NotoSansTamil': ['NotoSansTamil-Regular.ttf', 'NotoSansTamil-Bold.ttf'],
  };
  for (final MapEntry(key: family, value: files) in families.entries) {
    final loader = FontLoader(family);
    for (final file in files) {
      final bytes = await File('assets/fonts/$file').readAsBytes();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }
}

void main() {
  final now = DateTime.utc(2026, 10, 17, 12);
  final server = ServerConfig.create(
    id: 'srv-1',
    label: 'Build box',
    host: 'build.example.com',
    username: 'ada',
    authType: AuthType.password,
    tags: ['Clients'],
    now: DateTime.utc(2026, 5, 1),
  );

  setUpAll(loadFonts);

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  Widget shell(Widget child, {List<Override> overrides = const []}) {
    return ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(),
        home: child,
      ),
    );
  }

  testWidgets('hosts screen', (tester) async {
    phone(tester);
    final vault = VaultService(
      secureStore: MemorySecureStore(),
      metadataStore: MemoryMetadataStore(),
    );
    await vault.saveServer(server, const ServerCredentials(password: 'pw'));
    await vault.recordConnected('srv-1', DateTime.utc(2026, 10, 17, 9));
    await vault.saveServer(
      ServerConfig.create(
        id: 'srv-2',
        label: 'Home lab',
        host: '192.168.1.20',
        port: 2222,
        username: 'pi',
        authType: AuthType.password,
        tags: ['Personal'],
        now: DateTime.utc(2026, 5, 1),
      ),
      const ServerCredentials(password: 'pw'),
    );
    await tester.pumpWidget(
      shell(
        const HomeScreen(),
        overrides: [
          vaultServiceProvider.overrideWithValue(vault),
          clockProvider.overrideWithValue(() => now),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/hosts.png'),
    );
  });

  testWidgets('keys screen', (tester) async {
    phone(tester);
    final vault = VaultService(
      secureStore: MemorySecureStore(),
      metadataStore: MemoryMetadataStore(),
      clock: () => now,
    );
    final key = generateKey(KeyAlgorithm.ed25519);
    await vault.addKey(
      name: 'Phone',
      privateKey: key.privateKey,
      info: key.info,
    );
    await tester.pumpWidget(
      shell(
        const HomeScreen(initialTab: 1),
        overrides: [vaultServiceProvider.overrideWithValue(vault)],
      ),
    );
    await tester.pumpAndSettle();
    // The fingerprint of a generated key changes every run; blank it.
    await expectLater(
      find.byType(AppBar),
      matchesGoldenFile('goldens/keys_header.png'),
    );
  });

  testWidgets('settings screen', (tester) async {
    phone(tester);
    await tester.pumpWidget(shell(const SettingsScreen()));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings.png'),
    );
  });

  testWidgets('settings with the light terminal theme and a bar cursor', (
    tester,
  ) async {
    phone(tester);
    final prefs = MemoryPreferencesStore();
    await tester.pumpWidget(
      shell(
        const SettingsScreen(),
        overrides: [preferencesStoreProvider.overrideWithValue(prefs)],
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsScreen)),
    );
    await container
        .read(appSettingsProvider.notifier)
        .update(
          (s) => s.copyWith(
            terminalTheme: TerminalThemeId.light,
            cursor: CursorShape.bar,
          ),
        );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(TerminalPreview),
      matchesGoldenFile('goldens/terminal_preview_light.png'),
    );
  });

  testWidgets('host key sheet', (tester) async {
    phone(tester);
    final challenge = HostKeyChallenge(
      host: 'build.example.com',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:4k5ZZIUZsqSTfrwC1i37PlLMgG5qosKN5ZA6aci6E/w',
      completer: Completer<bool>(),
    );
    await tester.pumpWidget(
      shell(Scaffold(body: HostKeySheet(challenge: challenge))),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/host_key_sheet.png'),
    );
  });

  testWidgets('connection card: connecting, failed', (tester) async {
    tester.view.physicalSize = const Size(1080, 1500);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    Widget card(ConnectionCardModel model) => ConnectionCard(
      model: model,
      onCancel: () {},
      onDetails: () {},
      onRetry: () {},
      onEditHost: () {},
    );
    await tester.pumpWidget(
      shell(
        Scaffold(
          backgroundColor: const Color(0xFF0B0F10),
          body: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                card(
                  ConnectionCardModel.from(
                    state: const SSHConnectionState.connecting(
                      SSHConnectionStage.exchangingKeys,
                    ),
                    server: server,
                  ),
                ),
                const SizedBox(height: 16),
                card(
                  ConnectionCardModel.from(
                    state: const SSHConnectionState.error(
                      'raw',
                      SSHConnectionRefusedException('x'),
                      SSHConnectionStage.openingConnection,
                    ),
                    server: server,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // The spinner animates; one frame is enough.
    await tester.pump();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/connection_card.png'),
    );
  });

  testWidgets('key bar: both pages with CTRL armed', (tester) async {
    tester.view.physicalSize = const Size(1080, 520);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      shell(
        Scaffold(
          backgroundColor: const Color(0xFF0B0F10),
          body: Align(
            alignment: Alignment.bottomCenter,
            child: TerminalKeyboardBar(
              ctrl: ModifierLatch.once,
              alt: ModifierLatch.off,
              onToggleCtrl: () {},
              onToggleAlt: () {},
              onKey: (_) {},
              onText: (_) {},
              onPaste: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/key_bar_page1.png'),
    );
    await tester.drag(find.byType(PageView), const Offset(-400, 0));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/key_bar_page2.png'),
    );
  });
}
