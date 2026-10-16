import 'package:flutter/painting.dart';

/// Design tokens. Every color, radius and size in the UI comes from here.
abstract final class AppColors {
  static const background = Color(0xFF0E1214);
  static const terminalBackground = Color(0xFF0B0F10);
  static const surface = Color(0xFF161B1E);
  static const bar = Color(0xFF12171A);
  static const border = Color(0xFF222B2F);
  static const text = Color(0xFFE6EDEA);
  static const muted = Color(0xFF93A19B);
  static const accent = Color(0xFF5EE6B0);
  static const onAccent = Color(0xFF062A1E);
  static const warn = Color(0xFFF2B84B);
  static const error = Color(0xFFF2938C);

  // Shades derived from the tokens above, for states the tokens do not name.
  static const surfaceRaised = Color(0xFF1C2226);
  static const borderStrong = Color(0xFF34413F);
  static const accentSoft = Color(0xFF173A2F);
  static const errorSoft = Color(0xFF3A2220);
  static const onError = Color(0xFF3B0D09);
  static const warnSoft = Color(0xFF3A2E14);

  /// Host avatar colors, picked per host by [avatarColorFor].
  static const avatars = [
    Color(0xFF5EE6B0),
    Color(0xFF7AB8F5),
    Color(0xFFB69CF2),
    Color(0xFFF29CC8),
    Color(0xFFF2B84B),
    Color(0xFFF2938C),
    Color(0xFF6FD3E0),
    Color(0xFFB5DE6F),
  ];

  /// A stable avatar color for [key], the same on every run.
  static Color avatarColorFor(String key) {
    // FNV-1a: String.hashCode is not guaranteed to be stable across runs.
    var hash = 0x811c9dc5;
    for (final unit in key.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return avatars[hash % avatars.length];
  }
}

abstract final class AppRadii {
  static const card = 18.0;
  static const button = 14.0;
  static const key = 10.0;
}

abstract final class AppSizes {
  /// Smallest touch target.
  static const minTouch = 44.0;
  static const avatar = 46.0;
  static const avatarRadius = 14.0;
  static const terminalBar = 50.0;
  static const key = 44.0;
}

abstract final class AppFonts {
  static const ui = 'IBMPlexSans';
  static const mono = 'JetBrainsMono';

  /// Used for scripts the main fonts do not cover.
  static const fallback = ['NotoSansTamil'];
}
