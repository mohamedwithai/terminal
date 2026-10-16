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
    };
  }
}
