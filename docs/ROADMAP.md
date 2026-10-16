# Roadmap

Work goes milestone by milestone. For each one: `flutter analyze` is clean,
`flutter test` passes, the work is committed and pushed, CI is green, and
then work stops for a phone test. The next milestone starts on "next".

## Rules

- Verify every package API against its pub.dev source for the pinned
  version, and pin new packages to exact versions in `pubspec.yaml`.
- Never log or store secrets in plain text. No hardcoded hosts, users or
  passwords.
- Update `CLAUDE.md` when the architecture changes.
- Keep commits small, one milestone per commit group.

## Milestone A: pending fixes

1. Paste button in the terminal keyboard bar. *(done in 27e8784)*
2. If the clipboard text has a newline, a confirm dialog with a preview
   before pasting. Use bracketed paste when the remote app enabled it
   (`?2004h`). *(done in 27e8784)*
3. The power button in the app bar asks before disconnecting.
   *(done in 27e8784)*
4. If notification permission is denied, a one-time hint after connecting:
   "Notifications are off. Your session may disconnect when you switch
   apps." with an "Open settings" button. *(done)*

## Milestone B: stable signing key

1. Exact VPS commands: `keytool` to create `upload-keystore.jks` (RSA 4096,
   10000 days, alias `upload`), base64 it, and the four GitHub secrets to
   add: `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`.
2. `build.gradle.kts` reads signing from `key.properties` when present,
   otherwise uses debug signing.
3. Workflow: decode the secret, write `key.properties`, sign the release.
4. Never commit the keystore or passwords; add them to `.gitignore`.

Stop before pushing B until the secrets are confirmed as added.

## Milestone C: SSH keys inside the app

1. A "Keys" screen: generate Ed25519 (default) or RSA 4096 with an optional
   passphrase; import by paste or file picker.
2. Keys are stored in secure storage and reusable by many servers. The
   server form picks a saved key instead of pasting one each time.
3. Copy / share the public key in OpenSSH format; show its SHA256
   fingerprint.
4. Migrate existing per-server pasted keys into the key store.

## Milestone D: snippets

1. Save named commands (name, command, optional "run with Enter" flag).
   CRUD screen, stored in Hive.
2. A snippet button in the keyboard bar opens a searchable sheet; a tap
   inserts (or runs) the snippet in the current session.

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
