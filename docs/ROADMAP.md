# Roadmap

Order: **A** (done), **B** (done), **H**, **C**, **D**, **I**, **E**, **F**, **G**.

Work goes milestone by milestone. For each one: `flutter analyze` is clean,
`flutter test` passes, the work is committed and pushed, CI is green, and
then work stops for a phone test. The next milestone starts on "next"
(or as agreed for unattended runs).

## Rules

- Verify every package API against its pub.dev source for the pinned
  version, and pin new packages to exact versions in `pubspec.yaml`.
- Never log or store secrets in plain text. No hardcoded hosts, users or
  passwords.
- Update `CLAUDE.md` when the architecture changes.
- Keep commits small, one milestone per commit group.
- Never force-push or rewrite history.

## Milestone A: pending fixes *(done)*

1. Paste button in the terminal keyboard bar. *(27e8784)*
2. If the clipboard text has a newline, a confirm dialog with a preview
   before pasting. Use bracketed paste when the remote app enabled it
   (`?2004h`). *(27e8784)*
3. The power button in the app bar asks before disconnecting. *(27e8784)*
4. If notification permission is denied, a one-time hint after connecting:
   "Notifications are off. Your session may disconnect when you switch
   apps." with an "Open settings" button. *(054bc17)*

## Milestone B: stable signing key *(done, 42821f1, CI run #6)*

1. Exact VPS commands: `keytool` to create `upload-keystore.jks` (RSA 4096,
   10000 days, alias `upload`), base64 it, and the four GitHub secrets to
   add: `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`.
2. `build.gradle.kts` reads signing from `key.properties` when present,
   otherwise uses debug signing.
3. Workflow: decode the secret, write `key.properties`, sign the release.
4. Never commit the keystore or passwords; add them to `.gitignore`.

See `docs/SIGNING.md`. The CI release certificate SHA-256 matches the
keystore (`5fa08f91…e73433c0`).

## Milestone H: UI/UX and design system *(done except icon and splash, which wait for a name)*

Tokens live in one theme file and are used everywhere:

| Token | Value |
| --- | --- |
| background | `#0E1214` |
| terminal background | `#0B0F10` |
| surface | `#161B1E` |
| bars | `#12171A` |
| border | `#222B2F` |
| text | `#E6EDEA` |
| muted | `#93A19B` |
| accent | `#5EE6B0` (text on accent `#062A1E`) |
| warn | `#F2B84B` |
| error | `#F2938C` |

Radii: cards 18, buttons 14, keys 10. Touch targets at least 44dp. Fonts
bundled as assets: IBM Plex Sans (UI), JetBrains Mono (terminal), Noto Sans
Tamil as a fallback.

- **H1 Hosts:** letter avatar 46px, radius 14, a color per host. "Active
  now" section with a green dot and the tab count. Search. Tag chips
  (All / Personal / Clients / +). "Last connected" and auth type on each
  row. FAB "New host". Bottom nav Hosts / Keys / Snippets / Files.
- **H2 Host key (first connect):** bottom sheet, fingerprint in 4-character
  groups, Copy button, "How do I check?" with the `ssh-keygen -lf` command,
  Cancel / Trust & connect. No timeout while the sheet is open.
- **H3 Connecting:** compact card over the terminal, 5-segment progress,
  Cancel and Details. On an error, one plain sentence with Edit host /
  Retry; the full log only under Details.
- **H4 Terminal screen:** 50px bar (back, status dot green/amber/red, host
  name, cols x rows, snippets button, menu). Session tabs row under it.
  Key bar of 2 rows x 8 columns with 44px keys. Page 1: ESC TAB CTRL ALT
  | ~ / - and Home End PgUp PgDn and the arrows. Page 2 (swipe or dots):
  F1-F12, Ins, Del, Paste, Snippets. A hint line shows "CTRL armed /
  locked". Haptic on every key. Optional: volume keys as CTRL / up.
- **H5 Settings:** theme cards with a live preview (Ink as default,
  Dracula, One Dark, Light), font, size slider (remembered per host),
  cursor Block / Bar / Line, key bar 2 rows / 1 row, volume keys, haptics,
  app lock and "lock after".
- **H6 App name, icon and splash:** keep "SSH" for now and propose 3 names
  in the report; don't change the package id. Golden tests for each main
  screen.

## Milestone C: SSH keys inside the app *(done)*

1. A "Keys" screen: generate Ed25519 (default) or RSA 4096 with an optional
   passphrase; import by paste or file picker.
2. Keys are stored in secure storage and reusable by many servers. The
   server form picks a saved key instead of pasting one each time.
3. Copy / share the public key in OpenSSH format; show its SHA256
   fingerprint.
4. Migrate existing per-server pasted keys into the key store.

## Milestone D: snippets and automation

- **D1 Library:** search, tags, a "Runs automatically" section, a Run button
  per snippet, badges (steps, variables, hosts, asks first), import/export
  as JSON.
- **D2 Steps:** a snippet is an ordered list of steps. Each step has a
  command, a wait rule (prompt returns | text appears | seconds) and a
  timeout. Option: stop at the first failed step (exit code through a
  hidden marker such as `; echo __RC=$?`, never shown on screen).
- **D3 Variables:** detect `${NAME}`; types text / choice / secret; default
  value. Secrets are asked at run time and never stored. Never store sudo
  passwords.
- **D4 Triggers:** manual, on connect per host (suggest
  `tmux new -A -s main` so work survives reconnects), key bar button.
- **D5 Run sheet:** fill in variables, pick hosts, preview the resolved
  commands, "Ask before running" confirmation. Parallel runs on many hosts
  with per-host progress, Stop all, an output view. Keeps running in the
  background (foreground service) and notifies when done.
- **D6 Tests:** variable parsing, the step runner with a fake shell
  (success, a failure stops, timeout), the on-connect trigger.

## Milestone I: autocomplete

- **I1 Shell integration:** optional one-tap install of a small zsh/bash
  snippet that emits OSC 133 (prompt, command start/end and exit code) and
  OSC 7 (cwd), and parsing of both. Without it, track the keys typed since
  the last Enter / Ctrl+C.
- **I2 Sources, ranked:** remote paths for cd/ls/cat/nano/vim (cwd listed
  over a separate exec channel, cached 30s, never shown in the terminal),
  per-host history (local, at most 2000 entries; skip lines containing
  password/token/secret/key= and lines starting with a space), snippets,
  common commands.
- **I3 UI:** grey ghost text after the cursor; a panel above the key bar
  (at most 4 rows of 46px) with a source icon (/ folder, history, >_
  snippet) and a meta line ("14x, last 2h ago"); the first row
  highlighted; tap fills, long-press fills and presses Enter, → accepts the
  ghost text. The panel fades/slides in 180ms. Nothing runs without Enter.
- **I4 Settings:** toggle each source, clear the history per host.
- **I5 Tests:** ranking, the history filter, OSC 133/7 parsing, the
  fallback mode.

## Milestone E: app lock

1. Optional lock with fingerprint/face (`local_auth`) and a PIN fallback.
   Settings screen with on/off and a timeout (immediately / 1 min / 5 min).
2. Lock on app start and after the background timeout. Hide app contents in
   the recent-apps screen (`FLAG_SECURE` on Android).

## Milestone F: multiple sessions

1. Several sessions at once (same or different servers). Tabs or a session
   switcher in the terminal screen; each keeps its own terminal buffer.
2. The notification shows the count ("2 SSH sessions active").
3. Close one session without affecting the others.

## Milestone G: SFTP file browser

1. Per server: browse directories, sort, go up, refresh.
2. Download to the phone, upload from the phone (file picker), with progress
   and cancel. Rename, delete (with confirmation), new folder.
3. Reuse the existing SSH connection when one is open.
