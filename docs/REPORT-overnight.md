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

## Milestone D: snippets and automation (59cbe90, CI run #11, green)
Library (search, tags, "Runs automatically", badges, Run, import/export JSON),
editor (ordered steps with wait rules and timeouts, typed variables, stop at
first failure, ask first, on-connect hosts with a tmux tip), run sheet
(variables, host picker, masked preview, confirm), parallel multi-host runs
with per-host progress / output / Stop all that keep running in the
background and notify when done, on-connect triggers, key bar and terminal bar
snippet buttons. Tests: variables, file format, marker filter at every chunk
size, runner (success, failure stops, timeout, text, seconds, cancel),
multi-host runs, library UI, terminal integration.

Decisions and limits:
- Exit codes use a hidden `;echo __RC_x=$?` marker, so "prompt returns" needs a
  POSIX shell (not fish) and commands must not end in a `# comment`.
- Headless multi-host runs refuse unknown host keys ("connect once from
  Hosts and trust it"); I chose that over trusting silently.
- A snippet with variables never runs automatically on connect.
- Secrets exist only in the run sheet's fields; never saved, masked in the
  preview. A secret typed into a command appears in the shell history of the
  server the way any typed command does.
- The Kotlin `notify` code is verified only by the CI build.

Phone checklist for D:
1. Snippets tab, New snippet `echo hello`; run it on one host.
2. In a terminal, tap the snippet button and run it; no `__RC_` text shows.
3. A two-step snippet with stop-at-first-failure and a failing first step.
4. A snippet with a choice and a secret variable; check the preview is masked.
5. Run on two hosts; leave the screen, switch apps, wait for the notification.
6. Tick a host under "Run automatically on connect" with `tmux new -A -s main`.
7. Export, delete, import.

## Milestone I: autocomplete (88b0a2f, CI run #12, green)
Shell integration (OSC 133 / OSC 7) with a one-tap install from the terminal
menu (a visible, confirmed, base64 one-liner that appends to `~/.bashrc` or
`~/.zshrc` once; the script was tested against real bash and zsh), parsing of
both, a keystroke fallback, per-host history (max 2000, secrets and space-led
lines skipped), a ranked engine (paths, history, snippets, common), remote
folder listing over a separate exec channel (30s cache, never on screen), ghost
text, a 4-row panel, and settings (a switch per source, clear history per host).
Tests: ranking, history filter and cap, OSC parsing, the fallback tracker,
the directory lister, and terminal UI behavior (including password prompts).

Decisions and limits:
- Without the integration the working directory is unknown, so relative paths
  are not completed; absolute and `~/` paths still are.
- Anything typed at a prompt that ends in "password:" or similar is never kept,
  in either mode.
- With the integration only commands that exit 0 enter the history.
- The panel and ghost text stay off in full-screen programs.

Phone checklist for I:
1. Type `git p` after running `git push` once; grey text and a list appear.
2. Tap a row to fill; long-press one to fill and run; right arrow takes the ghost.
3. Terminal menu, Shell integration, Install; open a new shell. `cd ` then lists folders.
4. `sudo ls` and type the password: it must not appear in suggestions later.
5. Settings, Autocomplete: switch sources off; Clear history for the host.

## Milestone E: app lock (182503c, CI run #13, green)
PIN (4 to 12 digits; salted PBKDF2-SHA256 hash, never the PIN, in secure
storage), optional fingerprint or face (`local_auth`, biometrics only), lock on
start and after "Immediately / 1 minute / 5 minutes" in the background,
`FLAG_SECURE` while on (hidden in recent apps, no screenshots), a lock screen
with a PIN pad, escalating waits after five wrong tries that survive a restart,
and Settings to turn it on (PIN twice, then optional fingerprint, confirmed once
before it is relied on), turn it off (needs the PIN), change the PIN, and pick
the timeout.

Decisions and limits:
- The lock covers the app UI; open SSH sessions stay connected while locked.
- Forgot the PIN: clear the app's data (no recovery, by design).
- Returning from the file picker or share sheet does not lock, even with
  "Immediately".
- A lock whose PIN vanished from secure storage is switched off, not trusted.
- Screenshots are blocked while the lock is on (a side effect of FLAG_SECURE).
- The Kotlin and manifest changes (FlutterFragmentActivity, USE_BIOMETRIC,
  AppCompat themes, window channel) are verified only by the CI build.

Phone checklist for E:
1. Settings, Security, App lock: set a PIN; accept fingerprint if offered.
2. Press Home: recent apps shows a blank card (FLAG_SECURE). Reopen: lock screen.
3. Wrong PIN five times: it makes you wait; force-stop and reopen: still waiting.
4. Set "After 1 minute": leave for 30 s (opens), then 70 s (locks).
5. Pick a file to import a key: the app must not lock on return.
6. Turn the lock off with the PIN; change the PIN.

## Milestone F: multiple sessions
Several sessions at once, to the same or different hosts. A tab bar under the
terminal bar (status dot, host name, numbered when a host is open twice, close
button, + for a new session) switches between them; every tab keeps its own
terminal buffer, shell and connection, also while you browse the host list.
Back leaves the sessions open ("Active now" and a badge on Hosts show them);
tapping the host returns to its tab, the row menu opens another session.
Closing a tab ends that session only. The notification shows the count
("2 SSH sessions active"). Deleting a host closes its tabs.

Found and fixed on the way: `IndexedStack` destroyed the next pane's state when
a tab before it closed; panes are now a keyed `Stack`. "Active now" counted
headless snippet sessions too; it now counts open tabs.

Decisions and limits:
- Back no longer asks to disconnect; closing a tab (x, or Disconnect in the
  menu) does, when it is connected. "Disconnect" in the notification still ends
  every session.
- Tapping a host that is already open goes to its tab; use New session for a
  second one.
- Tabs live as long as the app process; they are not restored after it dies.

Phone checklist for F:
1. Open two hosts; type something in each; switch tabs: each keeps its screen.
2. Press Back: the host list shows "Active now"; tap a host: you return to it.
3. + in the tab bar, pick the same host: tabs "Name 1" and "Name 2".
4. Close one tab (x): only it disconnects; the other keeps running.
5. Pull the notification shade: "2 SSH sessions active".
