import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/providers/ssh_providers.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/screens/ssh_status_screen.dart';
import 'package:ssh_app/screens/terminal_screen.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';
import 'package:ssh_app/services/vault_service.dart';

import 'support/fake_ssh.dart';
import 'support/memory_stores.dart';

/// Answers after a delay, like Keystore behind a platform channel.
class SlowSecureStore extends MemorySecureStore {
  @override
  Future<String?> read(String key) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return super.read(key);
  }
}

void main() {
  final server = ServerConfig.create(
    id: 'srv-1',
    label: 'Build box',
    host: '10.0.0.5',
    username: 'ada',
    authType: AuthType.password,
    now: DateTime.utc(2026, 5, 1),
  );

  Finder chip(String label) => find.descendant(
        of: find.byType(Chip),
        matching: find.text(label),
      );

  testWidgets(
      'shows each stage, then a clear error when the handshake never finishes',
      (tester) async {
    // A typical Android phone screen.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);

    final metadata = MemoryMetadataStore();
    final vault = VaultService(
      secureStore: SlowSecureStore(),
      metadataStore: metadata,
    );
    await vault.saveServer(server, const ServerCredentials(password: 'p'));
    final sockets = FakeSSHSocketFactory(
      onConnect: (host, port, timeout) async => SilentSSHSocket(),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          metadataStoreProvider.overrideWithValue(metadata),
          vaultServiceProvider.overrideWithValue(vault),
          sshSocketFactoryProvider.overrideWithValue(sockets),
        ],
        child: MaterialApp(home: SSHStatusScreen(server: server)),
      ),
    );
    await tester.pump();
    expect(chip('Loading credentials'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(sockets.calls, ['10.0.0.5:22']);
    expect(chip('Exchanging keys'), findsOneWidget);
    // Loading credentials and Opening connection are done.
    expect(find.byIcon(Icons.check_circle), findsNWidgets(2));

    await tester.pump(const Duration(seconds: 29));
    expect(find.textContaining('Timed out'), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(chip('Error'), findsOneWidget);
    expect(find.text('Failed: Exchanging keys'), findsOneWidget);
    expect(
      find.textContaining('Timed out after 30s while exchanging keys'),
      findsOneWidget,
    );
    expect(find.text('Try Again'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Connection log'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Connection log'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Opening TCP connection to 10.0.0.5:22'), findsOneWidget);
    expect(
      find.textContaining('TimeoutException after 0:00:30.000000'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'host key dialog is displayed and sign-in waits until Accept',
    (tester) async {
      final harness = _Harness();
      await tester.pumpWidget(harness.app(server));
      harness.states.add(
        const SSHConnectionState.connecting(SSHConnectionStage.exchangingKeys),
      );
      await tester.pump();

      final challenge = harness.challenge();
      harness.states.add(SSHConnectionState.awaitingHostKeyConfirmation(challenge));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(HostKeyDialog), findsOneWidget);
      expect(find.text('SHA256:Q0ynKtbgRmoAoNdXUXjoMx9q+SQZX6WpGcyClsHHJBk'), findsOneWidget);
      expect(chip('Verifying host key'), findsOneWidget);

      // Nothing decides for the user, however long the dialog stays open.
      await tester.pump(const Duration(seconds: 20));
      expect(challenge.isCompleted, isFalse);

      await tester.tap(find.text('Accept & Save'));
      await tester.pump();
      expect(challenge.isCompleted, isTrue);
      expect(await challenge.decision, isTrue);

      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(HostKeyDialog), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'the system back button rejects the host key',
    (tester) async {
      final harness = _Harness();
      await tester.pumpWidget(harness.app(server));
      final challenge = harness.challenge();
      harness.states.add(SSHConnectionState.awaitingHostKeyConfirmation(challenge));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(HostKeyDialog), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(HostKeyDialog), findsNothing);
      expect(await challenge.decision, isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('the dialog closes itself when the attempt times out', (tester) async {
    final harness = _Harness();
    await tester.pumpWidget(harness.app(server));
    final challenge = harness.challenge();
    harness.states.add(SSHConnectionState.awaitingHostKeyConfirmation(challenge));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(HostKeyDialog), findsOneWidget);

    // What the session does when the 30s limit runs out.
    challenge.reject();
    harness.states.add(const SSHConnectionState.error(
      'Timed out after 30s waiting for the host key to be accepted.',
      null,
      SSHConnectionStage.verifyingHostKey,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(HostKeyDialog), findsNothing);
    expect(find.text('Failed: Verifying host key'), findsOneWidget);
    expect(find.textContaining('waiting for the host key'), findsOneWidget);
  });

  testWidgets('opens the shell after sign-in, then the terminal', (tester) async {
    final harness = _Harness();
    await tester.pumpWidget(harness.app(server));
    harness.states.add(const SSHConnectionState.connected());
    await tester.pump();
    expect(chip('Opening shell'), findsOneWidget);
    expect(harness.shellOpens, 1);

    harness.shell.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(TerminalScreen), findsOneWidget);
  });

  testWidgets('a shell that fails to open is reported as that stage', (tester) async {
    final harness = _Harness();
    await tester.pumpWidget(harness.app(server));
    harness.states.add(const SSHConnectionState.connected());
    await tester.pump();

    harness.shell.completeError(StateError('channel open refused'));
    await tester.pump();
    expect(find.text('Failed: Opening shell'), findsOneWidget);
    expect(find.textContaining('channel open refused'), findsOneWidget);
    expect(find.byType(TerminalScreen), findsNothing);
  });
}

/// Drives the status screen with hand-made connection states.
class _Harness {
  final states = StreamController<SSHConnectionState>.broadcast();
  final shell = Completer<void>();
  int shellOpens = 0;

  HostKeyChallenge challenge() => HostKeyChallenge(
        host: '10.0.0.5',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:Q0ynKtbgRmoAoNdXUXjoMx9q+SQZX6WpGcyClsHHJBk',
        completer: Completer<bool>(),
      );

  Widget app(ServerConfig server) {
    return ProviderScope(
      overrides: [
        metadataStoreProvider.overrideWithValue(MemoryMetadataStore()),
        sshSessionStateProvider.overrideWith((ref, args) => states.stream),
        sshSessionLogProvider.overrideWith((ref, args) => Stream.value(const [])),
        sshSessionControllerProvider.overrideWith((ref, args) {
          return _FakeController(
            ref: ref,
            sessionId: args.sessionId,
            server: args.server,
            harness: this,
          );
        }),
      ],
      child: MaterialApp(home: SSHStatusScreen(server: server)),
    );
  }
}

class _FakeController extends SSHSessionController {
  _FakeController({
    required super.ref,
    required super.sessionId,
    required super.server,
    required this.harness,
  });

  final _Harness harness;

  @override
  Future<void> connect() async {}

  @override
  Future<void> openShell() {
    harness.shellOpens++;
    return harness.shell.future;
  }

  @override
  Future<void> disconnect() async {}
}
