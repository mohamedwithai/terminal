# Overnight report

## Done and on `main` (CI green)
- Roadmap update: 9866767 (new order A, B, H, C, D, I, E, F, G; H, new D, I added).

## Milestone H: code and tests done, merged to `main`
Analyze clean, 132 tests pass (the old status-screen tests were replaced by
tests of the card, the sheet, the deadline and the Hosts screen).
- Design tokens (`lib/theme/tokens.dart`), dark theme from tokens, 4 terminal
  themes (Ink, Dracula, One Dark, Light), bundled fonts with OFL licenses.
- H1 Hosts + bottom nav (Keys / Snippets / Files are "coming soon").
  `ServerConfig` gained `tags` and `lastConnectedAt`.
- H2 host key sheet; the handshake limit pauses while it is open.
- H3 connecting card over the terminal (replaces the status screen).
- H4 terminal bar, tab row, paged 2x8 key bar, hint line, haptics, volume keys.
- H5 Settings screen with live theme preview. App lock is shown disabled.

H leftovers finished after the first report:
- Tag picker in the host form (pick, add; saved on the host and used by the
  Hosts filter chips).
- Golden tests for the main screens (`test/golden_test.dart`, images in
  `test/goldens/`, tolerant comparator in `test/flutter_test_config.dart`).
  They showed that "Last connected ..." was cut off on phones; it now wraps.
- Icon and splash are skipped until you pick a name.
- A dialog bug found by tests: disposing a text controller while its dialog
  was still closing crashed; a shared `TextPromptDialog` fixes the tag and
  key-rename prompts.

## Milestone C: SSH keys inside the app (8447eda, CI run #9, green)
Generate Ed25519 / RSA 4096 (optional passphrase), import by paste or file,
keys stored in secure storage and reusable by many hosts, host form picks a
saved key, copy/share public key and SHA256 fingerprint, startup migration of
per-host pasted keys. Fingerprints verified against `ssh-keygen -lf`;
generated keys verified with the real `ssh-keygen`.

Phone checklist for C:
1. Keys tab, Add key, Generate Ed25519; copy the public key.
2. Put it in `~/.ssh/authorized_keys` on a test server.
3. New host, Private key, pick the saved key, connect.
4. Repeat with a passphrase; import a key from a file.
5. Deleting a key a host uses is refused.
6. Hosts that had pasted keys now appear in Keys and still connect.


## Decisions taken (safest option)
- Terminal themes change only the terminal; the app chrome stays on the
  dark tokens.
- `preferencesStoreProvider` now defaults to an in-memory store (main.dart
  still overrides it with Hive), so widget tests need no override.
- Volume keys: volume down = CTRL, volume up = ↑, off by default.
- The tab row shows the current session only until milestone F.

## App name ideas
- Burrow
- Tether
- Shellpad

## Open questions
- Should Light also switch the app UI to light, or only the terminal?
- "Active now" stays empty until milestone F, because leaving the terminal
  ends the session today. OK?
