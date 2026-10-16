# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`ssh_app` is a Flutter SSH client and terminal emulator. It uses Riverpod 3 for state, `dartssh2` for SSH, `xterm` for the terminal, Hive for non-secret metadata, and `flutter_secure_storage` for secrets. Dependencies in `pubspec.yaml` are pinned to exact versions on purpose.

## Commands

```sh
flutter pub get
flutter analyze                                   # lints: flutter_lints; android/ios/web/build are excluded
flutter test                                      # unit + widget tests (the live SSH test is skipped by default)
flutter test test/vault_service_test.dart         # single file
flutter test test/vault_service_test.dart --plain-name "deletes"   # single test by name
flutter run                                       # on a device/emulator
flutter run -d chrome                             # web build, UI testing only (no SSH, see below)
```

Tests that need more setup:

- **Live SSH test** (`test/ssh_live_integration_test.dart`, tag `live`, skipped via `dart_test.yaml`). It needs `SSH_TEST_HOST` and `SSH_TEST_USER`, plus `SSH_TEST_PASSWORD` or `SSH_TEST_KEY_PATH` (`SSH_TEST_PORT` and `SSH_TEST_KEY_PASSPHRASE` are optional). There are deliberately no default credentials. Run it with:
  `flutter test --tags live --run-skipped test/ssh_live_integration_test.dart`
- **Device integration test** (`integration_test/credential_vault_test.dart`). It exercises the real Keystore/Keychain, so it must run on a device or emulator: `flutter test integration_test/credential_vault_test.dart -d <device>`.

CI (`.github/workflows/android-apk.yml`) runs on every push to `main` and on manual dispatch. It runs pub get, analyze, test, and `flutter build apk --debug` on Flutter 3.47.7, then uploads the APK as the `ssh-app-debug` artifact.

## Architecture

The layers are `screens/` → `providers/` → `services/` → `models/`.

### Vault (server storage)
- Server records are split across two stores behind interfaces: `MetadataStore` (non-secret `ServerConfig` and `KnownHost`, implemented by `HiveMetadataStore` as JSON strings in the Hive boxes `server_configs` and `known_hosts`) and `SecureStore` (secrets, implemented by `FlutterSecureStore`). Secrets must never go through `MetadataStore`.
- `VaultService` is the only thing that coordinates the two stores. Credentials are stored as JSON under the key `cred_<serverId>`. Every operation is serialized through an internal promise-chain lock (`_lock`). Writes are ordered so a failure never leaves a half-written record: on save the secret goes first and is rolled back if the metadata write fails on a new server, and on delete the secret is removed first. Validation errors come back as `VaultValidationException` with a field→message map that the form screen shows inline.
- Private keys are validated (`private_key_validator.dart`) before anything is written. The passphrase is kept only when the key is actually encrypted.
- `metadataStoreProvider` throws unless it is overridden. `main.dart` opens Hive and overrides it, and tests override it with the in-memory fakes in `test/support/memory_stores.dart` (`MemorySecureStore` and the metadata equivalent).

### SSH layer (`lib/services/ssh/`)
- This layer is kept free of Flutter imports so it can be tested in isolation. `SSHConnectionService` holds several `SSHConnectionSession`s keyed by session ID. Each session owns one `SSHClient`, an optional PTY shell, keepalive, and automatic reconnect with backoff (`reconnectDelays`, 2/4/8s by default). Reconnect is suppressed after an intentional `disconnect()`.
- Session state is published as `SSHConnectionState` on a broadcast `stateStream`. Errors are mapped into the typed exceptions in `ssh_errors.dart`.
- Host keys use trust-on-first-use (`HostKeyVerifier`). An unknown host emits an `awaitingHostKeyConfirmation` state carrying a `HostKeyChallenge`, and the UI must call accept/reject on it. A changed fingerprint throws `SSHHostKeyChangedException` and must never be auto-accepted. Accepted keys are saved as `KnownHost` records in the metadata store.
- `SSHSocketFactory` is the seam for injecting fake sockets in tests.
- On the web there are no raw sockets. `ssh_connection_session.dart` conditionally imports `io_stub.dart` in place of `dart:io`, and the providers in `ssh_providers.dart` short-circuit on `kIsWeb` (the state provider emits an error, and connect does nothing). The web target exists only for UI testing.
- The web secure store needs WebCrypto, which browsers expose only in a secure context (HTTPS or `localhost`). `secureStorageAvailableProvider` (backed by `secure_context.dart` / `secure_context_web.dart`) is false outside one. The server list then shows a banner and the form's Save button is disabled.

### Providers and UI flow
- `ssh_providers.dart`: `sshSessionStateProvider` and `sshSessionControllerProvider` are `autoDispose.family` providers keyed by the record `({String sessionId, ServerConfig server})`. When the state provider is disposed, it closes that session. `SSHSessionController.connect()` loads credentials from the vault and then connects.
- Navigation uses plain `Navigator.push`: `ServerListScreen` → (tap) `SSHStatusScreen` (connect, host-key prompt) → `TerminalScreen`. The edit/add actions open `ServerFormScreen`.
- `TerminalScreen` bridges `xterm`'s `Terminal` to the session's shell (`openShell`, `writeShell`, `resizeShell`) and decodes stdout as UTF-8 with `allowMalformed`. `TerminalKeyboardBar` provides the on-screen keys. CTRL and ALT are one-shot latches (`ModifierLatch`) that clear after the next key.
