import 'package:ssh_app/theme/terminal_themes.dart';
import 'package:ssh_app/theme/tokens.dart';
import 'package:xterm/xterm.dart';

enum TerminalFont {
  jetBrainsMono('JetBrains Mono'),
  system('System monospace');

  const TerminalFont(this.label);

  final String label;

  String get fontFamily => switch (this) {
    TerminalFont.jetBrainsMono => AppFonts.mono,
    TerminalFont.system => 'monospace',
  };
}

enum CursorShape {
  block('Block', TerminalCursorType.block),
  bar('Bar', TerminalCursorType.verticalBar),
  line('Line', TerminalCursorType.underline);

  const CursorShape(this.label, this.type);

  final String label;
  final TerminalCursorType type;
}

/// How long the app may be out of the foreground before it locks.
enum LockTimeout {
  immediately('Immediately', Duration.zero),
  oneMinute('After 1 minute', Duration(minutes: 1)),
  fiveMinutes('After 5 minutes', Duration(minutes: 5));

  const LockTimeout(this.label, this.duration);

  final String label;
  final Duration duration;
}

enum KeyBarLayout {
  twoRows('2 rows'),
  oneRow('1 row');

  const KeyBarLayout(this.label);

  final String label;
}

/// User settings. Stored as JSON in the preferences store; nothing secret.
class AppSettings {
  const AppSettings({
    this.terminalTheme = TerminalThemeId.ink,
    this.font = TerminalFont.jetBrainsMono,
    this.fontSize = defaultFontSize,
    this.cursor = CursorShape.block,
    this.keyBar = KeyBarLayout.twoRows,
    this.volumeKeys = false,
    this.haptics = true,
    this.hostFontSizes = const {},
    this.tags = defaultTags,
    this.autocomplete = true,
    this.completePaths = true,
    this.completeHistory = true,
    this.completeSnippets = true,
    this.completeCommon = true,
    this.appLock = false,
    this.lockTimeout = LockTimeout.immediately,
    this.lockBiometrics = false,
  });

  static const defaultFontSize = 14.0;
  static const minFontSize = 8.0;
  static const maxFontSize = 32.0;
  static const defaultTags = ['Personal', 'Clients'];

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) {
      for (final value in values) {
        if (value.name == name) {
          return value;
        }
      }
      return fallback;
    }

    final sizes = <String, double>{};
    final rawSizes = json['hostFontSizes'];
    if (rawSizes is Map) {
      for (final entry in rawSizes.entries) {
        final size = entry.value;
        if (entry.key is String && size is num) {
          sizes[entry.key as String] = _clampSize(size.toDouble());
        }
      }
    }
    final rawTags = json['tags'];
    final fontSize = json['fontSize'];
    return AppSettings(
      terminalTheme: pick(
        TerminalThemeId.values,
        json['terminalTheme'],
        TerminalThemeId.ink,
      ),
      font: pick(TerminalFont.values, json['font'], TerminalFont.jetBrainsMono),
      fontSize: fontSize is num
          ? _clampSize(fontSize.toDouble())
          : defaultFontSize,
      cursor: pick(CursorShape.values, json['cursor'], CursorShape.block),
      keyBar: pick(KeyBarLayout.values, json['keyBar'], KeyBarLayout.twoRows),
      volumeKeys: json['volumeKeys'] == true,
      haptics: json['haptics'] != false,
      hostFontSizes: sizes,
      appLock: json['appLock'] == true,
      lockTimeout: pick(
        LockTimeout.values,
        json['lockTimeout'],
        LockTimeout.immediately,
      ),
      lockBiometrics: json['lockBiometrics'] == true,
      autocomplete: json['autocomplete'] != false,
      completePaths: json['completePaths'] != false,
      completeHistory: json['completeHistory'] != false,
      completeSnippets: json['completeSnippets'] != false,
      completeCommon: json['completeCommon'] != false,
      tags: rawTags is List
          ? [
              for (final tag in rawTags)
                if (tag is String && tag.trim().isNotEmpty) tag.trim(),
            ]
          : defaultTags,
    );
  }

  final TerminalThemeId terminalTheme;
  final TerminalFont font;

  /// Font size for hosts without their own.
  final double fontSize;
  final CursorShape cursor;
  final KeyBarLayout keyBar;

  /// Volume down arms CTRL and volume up sends the up arrow.
  final bool volumeKeys;
  final bool haptics;

  /// Font size per server id, remembered from pinch-zoom.
  final Map<String, double> hostFontSizes;

  /// Tags offered on the Hosts screen and in the host form.
  final List<String> tags;

  /// Suggest completions while typing, and which sources feed them.
  final bool autocomplete;
  final bool completePaths;
  final bool completeHistory;
  final bool completeSnippets;
  final bool completeCommon;

  /// The app asks for a PIN (or fingerprint or face) on start and after
  /// [lockTimeout] in the background. The PIN itself is in secure storage.
  final bool appLock;
  final LockTimeout lockTimeout;

  /// Unlock with fingerprint or face as well as the PIN.
  final bool lockBiometrics;

  double fontSizeFor(String serverId) => hostFontSizes[serverId] ?? fontSize;

  static double _clampSize(double size) =>
      size.clamp(minFontSize, maxFontSize).toDouble();

  AppSettings copyWith({
    TerminalThemeId? terminalTheme,
    TerminalFont? font,
    double? fontSize,
    CursorShape? cursor,
    KeyBarLayout? keyBar,
    bool? volumeKeys,
    bool? haptics,
    Map<String, double>? hostFontSizes,
    List<String>? tags,
    bool? autocomplete,
    bool? completePaths,
    bool? completeHistory,
    bool? completeSnippets,
    bool? completeCommon,
    bool? appLock,
    LockTimeout? lockTimeout,
    bool? lockBiometrics,
  }) {
    return AppSettings(
      terminalTheme: terminalTheme ?? this.terminalTheme,
      font: font ?? this.font,
      fontSize: fontSize == null ? this.fontSize : _clampSize(fontSize),
      cursor: cursor ?? this.cursor,
      keyBar: keyBar ?? this.keyBar,
      volumeKeys: volumeKeys ?? this.volumeKeys,
      haptics: haptics ?? this.haptics,
      hostFontSizes: hostFontSizes ?? this.hostFontSizes,
      tags: tags ?? this.tags,
      autocomplete: autocomplete ?? this.autocomplete,
      completePaths: completePaths ?? this.completePaths,
      completeHistory: completeHistory ?? this.completeHistory,
      completeSnippets: completeSnippets ?? this.completeSnippets,
      completeCommon: completeCommon ?? this.completeCommon,
      appLock: appLock ?? this.appLock,
      lockTimeout: lockTimeout ?? this.lockTimeout,
      lockBiometrics: lockBiometrics ?? this.lockBiometrics,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'terminalTheme': terminalTheme.name,
      'font': font.name,
      'fontSize': fontSize,
      'cursor': cursor.name,
      'keyBar': keyBar.name,
      'volumeKeys': volumeKeys,
      'haptics': haptics,
      'hostFontSizes': hostFontSizes,
      'tags': tags,
      'autocomplete': autocomplete,
      'completePaths': completePaths,
      'completeHistory': completeHistory,
      'completeSnippets': completeSnippets,
      'completeCommon': completeCommon,
      'appLock': appLock,
      'lockTimeout': lockTimeout.name,
      'lockBiometrics': lockBiometrics,
    };
  }
}
