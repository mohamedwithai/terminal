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

Left for H:
- Tag picker in the host form (tags can only be created from the Hosts
  screen chips today, and assigned nowhere yet).
- H6: new icon and splash colors; golden tests for the main screens.
- Not yet checked on a phone.

## Milestone C: not started.

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
