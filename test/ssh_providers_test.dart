import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/providers/ssh_providers.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';
import 'package:ssh_app/services/ssh/ssh_errors.dart';
import 'package:ssh_app/services/vault_service.dart';

import 'support/fake_ssh.dart';
import 'support/memory_stores.dart';

/// Answers after a real delay, like Keystore behind a platform channel.
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
    port: 2222,
    username: 'ada',
    authType: AuthType.password,
  );

  // Regression: the controller provider is auto-disposed and only read, so
  // it was disposed while the vault answered. Its next ref.read threw
  // UnmountedRefException, the status screen swallowed it, no socket was
  // ever opened, and the screen showed "Connecting..." forever.
  test('connect opens the socket even when the vault answers late', () async {
    final metadata = MemoryMetadataStore();
    final vault = VaultService(
      secureStore: SlowSecureStore(),
      metadataStore: metadata,
    );
    await vault.saveServer(server, const ServerCredentials(password: 'p'));
    final sockets = FakeSSHSocketFactory();
    final container = ProviderContainer(
      overrides: [
        metadataStoreProvider.overrideWithValue(metadata),
        vaultServiceProvider.overrideWithValue(vault),
        sshSocketFactoryProvider.overrideWithValue(sockets),
      ],
    );
    addTearDown(container.dispose);

    final args = (sessionId: 'session-1', server: server);
    final states = <SSHConnectionState>[];
    container.listen(sshSessionStateProvider(args), (_, next) {
      final state = next.asData?.value;
      if (state != null) states.add(state);
    });
    final log = container.listen(sshSessionLogProvider(args), (_, _) {});

    await expectLater(
      container.read(sshSessionControllerProvider(args)).connect(),
      throwsA(isA<SSHConnectionRefusedException>()),
    );
    await pumpEventQueue();

    expect(sockets.calls, ['10.0.0.5:2222']);
    expect(states.last.status, SSHConnectionStatus.error);
    expect(states.last.stage, SSHConnectionStage.openingConnection);

    final messages = log.read().asData?.value.map((entry) => entry.message);
    expect(messages, contains('Reading saved credentials'));
    expect(
      messages,
      contains('Opening TCP connection to 10.0.0.5:2222 (limit 10s)'),
    );
  });

  test(
    'a server without saved credentials ends in an error, not a hang',
    () async {
      final metadata = MemoryMetadataStore();
      final vault = VaultService(
        secureStore: MemorySecureStore(),
        metadataStore: metadata,
      );
      final container = ProviderContainer(
        overrides: [
          metadataStoreProvider.overrideWithValue(metadata),
          vaultServiceProvider.overrideWithValue(vault),
          sshSocketFactoryProvider.overrideWithValue(FakeSSHSocketFactory()),
        ],
      );
      addTearDown(container.dispose);

      final args = (sessionId: 'session-2', server: server);
      container.listen(sshSessionStateProvider(args), (_, _) {});

      await expectLater(
        container.read(sshSessionControllerProvider(args)).connect(),
        throwsA(isA<SSHCredentialsException>()),
      );
      await pumpEventQueue();

      final state = container.read(sshSessionStateProvider(args)).asData?.value;
      expect(state?.status, SSHConnectionStatus.error);
      expect(state?.stage, SSHConnectionStage.loadingCredentials);
    },
  );
}
