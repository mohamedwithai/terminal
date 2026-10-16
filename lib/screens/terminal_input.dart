import 'package:flutter/foundation.dart';
import 'package:ssh_app/screens/terminal_keyboard_bar.dart';
import 'package:xterm/xterm.dart';

/// The control character CTRL turns [codePoint] into, or null if it has none.
///
/// Letters map to 0x01-0x1A in either case (Ctrl+C is 0x03, Ctrl+L 0x0C),
/// `@` and space to NUL, `[ \ ] ^ _` to 0x1B-0x1F (so Ctrl+[ is ESC), `/` to
/// 0x1F and `?` to DEL, as xterm does.
int? controlCode(int codePoint) {
  if (codePoint == 0x20) return 0x00;
  if (codePoint == 0x2f) return 0x1f;
  if (codePoint == 0x3f) return 0x7f;
  if ((codePoint >= 0x40 && codePoint <= 0x5f) ||
      (codePoint >= 0x61 && codePoint <= 0x7a)) {
    return codePoint & 0x1f;
  }
  return null;
}

/// [text] as a terminal sends it while CTRL and/or ALT are held.
///
/// Only the first character is modified, because a modifier applies to one
/// key and an IME may commit a whole word at once. CTRL replaces it with its
/// [controlCode] (a character without one is sent unchanged) and ALT puts ESC
/// in front of it.
String applyModifiers(String text, {bool ctrl = false, bool alt = false}) {
  if (text.isEmpty || (!ctrl && !alt)) {
    return text;
  }
  final first = text.runes.first;
  final rest = text.substring(first > 0xffff ? 2 : 1);
  final key = ctrl ? (controlCode(first) ?? first) : first;
  return '${alt ? '\x1b' : ''}${String.fromCharCode(key)}$rest';
}

/// The on-screen CTRL and ALT keys.
class TerminalModifiers extends ChangeNotifier {
  var _ctrl = ModifierLatch.off;
  var _alt = ModifierLatch.off;

  ModifierLatch get ctrl => _ctrl;
  ModifierLatch get alt => _alt;

  /// Whether either modifier applies to the next key.
  bool get isArmed => _ctrl.isActive || _alt.isActive;

  void toggleCtrl() {
    _ctrl = advanceModifierLatch(_ctrl);
    notifyListeners();
  }

  void toggleAlt() {
    _alt = advanceModifierLatch(_alt);
    notifyListeners();
  }

  /// The modifiers for the key being sent now. A one-shot modifier turns off;
  /// a locked one stays on.
  ({bool ctrl, bool alt}) take() {
    final taken = (ctrl: _ctrl.isActive, alt: _alt.isActive);
    final ctrl = releaseOneShotModifier(_ctrl);
    final alt = releaseOneShotModifier(_alt);
    if (ctrl != _ctrl || alt != _alt) {
      _ctrl = ctrl;
      _alt = alt;
      notifyListeners();
    }
    return taken;
  }
}

/// A [Terminal] that applies the on-screen CTRL and ALT keys to all input.
///
/// [TerminalView] turns soft keyboard text, IME commits and hardware keys into
/// [keyInput] and [textInput] calls, and the keyboard bar uses the same two,
/// so these overrides are the one place an armed modifier is applied.
class ModifierTerminal extends Terminal {
  ModifierTerminal({required this.modifiers, super.maxLines});

  final TerminalModifiers modifiers;

  var _pasting = false;

  @override
  bool keyInput(
    TerminalKey key, {
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
  }) {
    if (!modifiers.isArmed || (!alt && !ctrl && _isTextKey(key))) {
      return super.keyInput(key, shift: shift, alt: alt, ctrl: ctrl);
    }
    final armed = modifiers.take();
    return super.keyInput(
      key,
      shift: shift,
      alt: alt || armed.alt,
      ctrl: ctrl || armed.ctrl,
    );
  }

  @override
  void textInput(String text) {
    if (_pasting || text.isEmpty || !modifiers.isArmed) {
      super.textInput(text);
      return;
    }
    final armed = modifiers.take();
    super.textInput(applyModifiers(text, ctrl: armed.ctrl, alt: armed.alt));
  }

  /// Pasted text is sent as it is, whatever modifier is armed.
  @override
  void paste(String text) {
    _pasting = true;
    try {
      super.paste(text);
    } finally {
      _pasting = false;
    }
  }

  /// Whether [key] has no sequence of its own and reaches the program as
  /// text, like a letter.
  ///
  /// [TerminalView] offers a single character from the soft keyboard to
  /// [keyInput] first, and sends it to [textInput] when that returns false.
  /// The modifier is left for [textInput], which knows the character's case.
  bool _isTextKey(TerminalKey key) {
    final handler = inputHandler;
    if (handler == null) {
      return true;
    }
    final plain = TerminalKeyboardEvent(
      key: key,
      shift: false,
      ctrl: false,
      alt: false,
      state: this,
      altBuffer: isUsingAltBuffer,
      platform: platform,
    );
    return handler(plain) == null;
  }
}
