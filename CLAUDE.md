# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`ssh_app` is a Flutter SSH client and terminal emulator. It uses Riverpod 3 for state, `dartssh2` for SSH, `xterm` for the terminal, Hive for non-secret metadata, `flutter_secure_storage` for secrets, and `connectivity_plus` to hold reconnects while offline. Dependencies in `pubspec.yaml` are pinned to exact versions on purpose.

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

CI (`.github/workflows/android-apk.yml`) runs on every push to `main` and on manual dispatch. It runs pub get, analyze, test, `flutter build apk --debug` and `flutter build apk --release` (signed with the debug key) on Flutter 3.47.7, then uploads the APKs as the `ssh-app-debug` and `ssh-app-release` artifacts.

## Architecture

The layers are `screens/` → `providers/` → `services/` → `models/`.

### Vault (server storage)
- Server records are split across two stores behind interfaces: `MetadataStore` (non-secret `ServerConfig` and `KnownHost`, implemented by `HiveMetadataStore` as JSON strings in the Hive boxes `server_configs` and `known_hosts`) and `SecureStore` (secrets, implemented by `FlutterSecureStore`). Secrets must never go through `MetadataStore`.
- `VaultService` is the only thing that coordinates the two stores. Credentials are stored as JSON under the key `cred_<serverId>`. Every operation is serialized through an internal promise-chain lock (`_lock`). Writes are ordered so a failure never leaves a half-written record: on save the secret goes first and is rolled back if the metadata write fails on a new server, and on delete the secret is removed first. Validation errors come back as `VaultValidationException` with a field→message map that the form screen shows inline.
- Private keys are validated (`private_key_validator.dart`) before anything is written. The passphrase is kept only when the key is actually encrypted.
- `metadataStoreProvider` throws unless it is overridden. `main.dart` opens Hive and overrides it, and tests override it with the in-memory fakes in `test/support/memory_stores.dart` (`MemorySecureStore` and the metadata equivalent).

### SSH layer (`lib/services/ssh/`)
- This layer is kept free of Flutter imports so it can be tested in isolation. `SSHConnectionService` holds several `SSHConnectionSession`s keyed by session ID. Each session owns one `SSHClient`, an optional PTY shell, keepalive, and automatic reconnect with backoff (`reconnectDelays`, 2/4/8s by default). Reconnect is suppressed after an intentional `disconnect()`.
- Reconnects go through a shared `ReconnectGate` (`reconnect_gate.dart`): while the app is in the background or offline, a lost session emits `reconnecting` with `waitingFor` set and spends no attempts. When the gate opens it starts over with all of them, and an attempt that fails after the gate closed is not counted. Tests drive this with `debugSimulateConnectionLost`, since there is no in-process SSH server. `isActive` (connected or reconnecting) is what keeps the foreground service running. `SSHConnectionService.changes` emits on any session change.
- Session state is published as `SSHConnectionState` on a broadcast `stateStream`. While connecting, `state.stage` is the current `SSHConnectionStage` (loading credentials, opening connection, exchanging keys, verifying host key, authenticating); on an error it is the stage that failed. Errors are mapped into the typed exceptions in `ssh_errors.dart`.
- `connectWith(loader)` loads credentials and connects; every failure ends in an error state, never a silent hang. Limits: `credentialsTimeout` 10s, `connectTimeout` 10s for TCP, `handshakeTimeout` 30s shared by key exchange, host-key verification (including time the user takes in the dialog) and authentication, `shellTimeout` 15s. A new connect, `disconnect()` or `dispose()` abandons the attempt in flight through an attempt counter, so its late callbacks change nothing.
- Each session keeps a `ConnectionLog` (timestamped steps, filtered dartssh2 debug lines, exact exception text) that the status screen shows. Never write secrets to it.
- Host keys use trust-on-first-use (`HostKeyVerifier`). An unknown host emits an `awaitingHostKeyConfirmation` state carrying a `HostKeyChallenge`, and the UI must call accept/reject on it. dartssh2 awaits that decision before sending NEWKEYS, so authentication cannot start before Accept. A changed fingerprint throws `SSHHostKeyChangedException` and must never be auto-accepted. Accepted keys are saved as `KnownHost` records in the metadata store. Fingerprints are the `SHA256:...` text `ssh-keygen -lf` prints; dartssh2 4 passes that text already encoded as UTF-8.
- `SSHSocketFactory` is the seam for injecting fake sockets in tests (`sshSocketFactoryProvider`; fakes in `test/support/fake_ssh.dart`).
- On the web there are no raw sockets. `ssh_connection_session.dart` conditionally imports `io_stub.dart` in place of `dart:io`, and the providers in `ssh_providers.dart` short-circuit on `kIsWeb` (the state provider emits an error, and connect does nothing). The web target exists only for UI testing.
- The web secure store needs WebCrypto, which browsers expose only in a secure context (HTTPS or `localhost`). `secureStorageAvailableProvider` (backed by `secure_context.dart` / `secure_context_web.dart`) is false outside one. The server list then shows a banner and the form's Save button is disabled.

### Background sessions (Android)
- `SessionKeeper` (`session_keeper.dart`, started by `sessionKeeperProvider`) feeds `AppLifecycleListener` and `NetworkMonitor` (connectivity_plus) into the `ReconnectGate`. Inactive counts as foreground, hidden and paused do not. It also runs `SessionForegroundService` while any session is active, asks for notification permission once at the first connect, and handles the notification's Disconnect by calling `disconnectAll()`.
- Only `main.dart` starts it (`SessionKeeperScope`), so widget tests that pump `SshApp` never touch the connectivity or method-channel plugins.
- The native side is `SessionForegroundService.kt` plus a `MethodChannel` (`ssh_app/session_foreground_service`) in `MainActivity.kt`. The service type is `specialUse`, because `dataSync` is capped at 6 hours a day on Android 15. Never stop the service before its `startForeground()`: that crashes the app, so a pending start stops itself in `onStartCommand` instead. The activity's `onDestroy` stops it, since the sessions live in that Flutter engine.

### Providers and UI flow
- `ssh_providers.dart`: `sshSessionStateProvider`, `sshSessionLogProvider` and `sshSessionControllerProvider` are `autoDispose.family` providers keyed by the record `({String sessionId, ServerConfig server})`. When the state provider is disposed, it closes that session. `SSHSessionController.connect()` hands the session a loader that reads the vault.
- The controller provider is auto-disposed and only ever `read`, so it is disposed almost immediately. Its methods must take everything they need from `ref` before their first `await`; a `ref.read` after an `await` throws `UnmountedRefException`. That bug once left the status screen on "Connecting..." without ever opening a socket.
- Navigation uses plain `Navigator.push`: `ServerListScreen` → (tap) `SSHStatusScreen` (stage list, host-key dialog, connection log; opens the shell) → `TerminalScreen`, which takes over the already open shell (`openShell` returns it and resizes it). The edit/add actions open `ServerFormScreen`.
- `TerminalScreen` bridges `xterm`'s `Terminal` to the session's shell (`openShell`, `writeShell`, `resizeShell`) and decodes stdout as UTF-8 with `allowMalformed`. `TerminalKeyboardBar` provides the on-screen keys. CTRL and ALT are one-shot latches (`ModifierLatch`) that clear after the next key.
- All input goes through `ModifierTerminal` (`terminal_input.dart`), a `Terminal` subclass. TerminalView sends soft keyboard text, IME commits and hardware keys into `keyInput`/`textInput`, and so does the keyboard bar, so that is the one place the armed modifier (`TerminalModifiers`) is applied. A key xterm has no plain sequence for, such as a letter, returns false from `keyInput` so TerminalView falls back to `textInput` with the real character. CTRL maps through `controlCode` (`& 0x1f`) and ALT adds an ESC prefix, applied to the first character only. Paste bypasses modifiers.
- xterm reports resizes during layout, on every frame of the keyboard animation. `PtyResizeDebouncer` sends only the final size after 100ms, as the whole window in pixels (xterm passes the cell size), and `opened()` resends it if the view changed while a shell was opening.
- On `reconnecting` the terminal drops its shell. On the next `connected` it resets terminal modes, prints `--- reconnected, new shell ---` and opens a new shell at the current size. A shell that ends while its client is still open was an `exit`: it prints `[session closed]` and is not replaced.
- `TerminalSelectionOverlay` (`terminal_selection.dart`) adds Material handles and a Copy / Select all / Paste toolbar around TerminalView's own long-press selection, plus a Paste menu for a long press over empty space. It needs `RenderTerminal`, which xterm does not export (hence the one implementation import). `terminalSelectionText` turns empty cells into spaces and trims each line, unlike `Buffer.getText`, which drops empty cells.
