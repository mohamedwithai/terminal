# Overnight report (stopped early: usage limit)

## Done and on `main` (CI green)
- Roadmap update: 9866767 (new order A, B, H, C, D, I, E, F, G; H, new D, I added).

## Milestone H: in progress, on branch `wip/milestone-h` (not merged, CI not run)
Done in code (`flutter analyze lib` clean, test suite NOT yet updated):
- Design tokens (`lib/theme/tokens.dart`), dark theme from tokens, 4 terminal
  themes (Ink, Dracula, One Dark, Light).
- Bundled fonts with OFL licenses: IBM Plex Sans, JetBrains Mono, Noto Sans
  Tamil (`assets/fonts/`, registered on the licenses page).
- H1: Home with bottom nav (Hosts / Keys / Snippets / Files; the last three
  are "coming soon"), Hosts screen with letter avatars, search, tag chips,
  "Active now", last connected + auth type, FAB "New host". `ServerConfig`
  gained `tags` and `lastConnectedAt` (backward compatible JSON).
- H2: host key bottom sheet (4-char groups, copy, "How do I check?" with the
  matching `ssh-keygen -lf` command). The handshake limit now pauses while
  the sheet is open (`PausableDeadline`).
- H3: connecting card over the terminal (5 segments, Cancel/Details, plain
  error sentence with Edit host / Retry, log under Details). The old
  SSHStatusScreen and its test were removed; tapping a host opens the
  terminal directly.
- H4: 50px terminal bar, session tab row, 2x8 key bar with 2 pages (or 1-row
  mode), modifier hint line, haptics, optional volume keys.
- H5: Settings screen (theme cards + live preview, font, size, cursor, key
  bar rows, volume keys, haptics; app lock shown disabled until milestone E).

Left for H:
- Form: tag picker for a host (tags can be created on the Hosts screen).
- Update tests for the new screens (terminal_screen_test, widget_test,
  server_form_screen_test, terminal_keyboard_bar_test), port the old
  status-screen tests to the card/sheet, add tests for PausableDeadline,
  groupFingerprint, plainConnectionError, AppSettings JSON, model fields.
- H6: icon and splash in the new colors; golden tests for the main screens.
- CLAUDE.md architecture update, then merge to `main` and CI.

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
