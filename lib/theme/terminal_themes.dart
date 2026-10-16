import 'package:flutter/painting.dart';
import 'package:ssh_app/theme/tokens.dart';
import 'package:xterm/xterm.dart';

/// The terminal color schemes a user can pick in Settings.
enum TerminalThemeId {
  ink('Ink'),
  dracula('Dracula'),
  oneDark('One Dark'),
  light('Light');

  const TerminalThemeId(this.label);

  final String label;

  TerminalTheme get theme => switch (this) {
    TerminalThemeId.ink => _ink,
    TerminalThemeId.dracula => _dracula,
    TerminalThemeId.oneDark => _oneDark,
    TerminalThemeId.light => _light,
  };
}

/// The default: the app's own tokens.
const _ink = TerminalTheme(
  cursor: AppColors.accent,
  selection: Color(0x665EE6B0),
  foreground: AppColors.text,
  background: AppColors.terminalBackground,
  black: Color(0xFF1C2326),
  red: AppColors.error,
  green: AppColors.accent,
  yellow: AppColors.warn,
  blue: Color(0xFF7AB8F5),
  magenta: Color(0xFFC9A0F2),
  cyan: Color(0xFF6FD3E0),
  white: Color(0xFFC7D1CD),
  brightBlack: Color(0xFF5D6B66),
  brightRed: Color(0xFFF7B2AC),
  brightGreen: Color(0xFF8FF0C9),
  brightYellow: Color(0xFFF7CE7A),
  brightBlue: Color(0xFFA3CEF8),
  brightMagenta: Color(0xFFDCC0F7),
  brightCyan: Color(0xFF9CE3EC),
  brightWhite: Color(0xFFF4F8F6),
  searchHitBackground: AppColors.warn,
  searchHitBackgroundCurrent: AppColors.accent,
  searchHitForeground: AppColors.terminalBackground,
);

/// https://draculatheme.com/contribute#color-palette
const _dracula = TerminalTheme(
  cursor: Color(0xFFF8F8F2),
  selection: Color(0x9944475A),
  foreground: Color(0xFFF8F8F2),
  background: Color(0xFF282A36),
  black: Color(0xFF21222C),
  red: Color(0xFFFF5555),
  green: Color(0xFF50FA7B),
  yellow: Color(0xFFF1FA8C),
  blue: Color(0xFFBD93F9),
  magenta: Color(0xFFFF79C6),
  cyan: Color(0xFF8BE9FD),
  white: Color(0xFFF8F8F2),
  brightBlack: Color(0xFF6272A4),
  brightRed: Color(0xFFFF6E6E),
  brightGreen: Color(0xFF69FF94),
  brightYellow: Color(0xFFFFFFA5),
  brightBlue: Color(0xFFD6ACFF),
  brightMagenta: Color(0xFFFF92DF),
  brightCyan: Color(0xFFA4FFFF),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFFF1FA8C),
  searchHitBackgroundCurrent: Color(0xFF50FA7B),
  searchHitForeground: Color(0xFF282A36),
);

const _oneDark = TerminalTheme(
  cursor: Color(0xFF528BFF),
  selection: Color(0x993E4451),
  foreground: Color(0xFFABB2BF),
  background: Color(0xFF282C34),
  black: Color(0xFF3F4451),
  red: Color(0xFFE06C75),
  green: Color(0xFF98C379),
  yellow: Color(0xFFE5C07B),
  blue: Color(0xFF61AFEF),
  magenta: Color(0xFFC678DD),
  cyan: Color(0xFF56B6C2),
  white: Color(0xFFD7DAE0),
  brightBlack: Color(0xFF5C6370),
  brightRed: Color(0xFFF07C85),
  brightGreen: Color(0xFFA8D389),
  brightYellow: Color(0xFFF0CD8B),
  brightBlue: Color(0xFF71BFFF),
  brightMagenta: Color(0xFFD688ED),
  brightCyan: Color(0xFF66C6D2),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFFE5C07B),
  searchHitBackgroundCurrent: Color(0xFF98C379),
  searchHitForeground: Color(0xFF282C34),
);

const _light = TerminalTheme(
  cursor: Color(0xFF0E7C66),
  selection: Color(0x665EE6B0),
  foreground: Color(0xFF1E2A26),
  background: Color(0xFFFAFBFA),
  black: Color(0xFF1E2A26),
  red: Color(0xFFC0392B),
  green: Color(0xFF0E7C66),
  yellow: Color(0xFF9A6B00),
  blue: Color(0xFF1F5FBF),
  magenta: Color(0xFF8E3FB5),
  cyan: Color(0xFF0E7C8C),
  white: Color(0xFFD5DCD9),
  brightBlack: Color(0xFF6B7A74),
  brightRed: Color(0xFFD9534F),
  brightGreen: Color(0xFF12A07F),
  brightYellow: Color(0xFFB98A00),
  brightBlue: Color(0xFF3A7BD5),
  brightMagenta: Color(0xFFA55CC9),
  brightCyan: Color(0xFF1798A8),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFFF2B84B),
  searchHitBackgroundCurrent: Color(0xFF5EE6B0),
  searchHitForeground: Color(0xFF1E2A26),
);
