import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ssh_app/models/app_settings.dart';
import 'package:ssh_app/theme/tokens.dart';
import 'package:xterm/xterm.dart';

/// How long a modifier stays applied.
///
/// One press arms [ModifierLatch.once] for the next key, then it turns off.
/// A second press while armed moves to [ModifierLatch.locked] until pressed again.
enum ModifierLatch { off, once, locked }

/// Next latch after the modifier key is pressed.
ModifierLatch advanceModifierLatch(ModifierLatch current) {
  return switch (current) {
    ModifierLatch.off => ModifierLatch.once,
    ModifierLatch.once => ModifierLatch.locked,
    ModifierLatch.locked => ModifierLatch.off,
  };
}

/// Clears a one-shot latch after a key is sent. A lock stays on.
ModifierLatch releaseOneShotModifier(ModifierLatch current) {
  return current == ModifierLatch.once ? ModifierLatch.off : current;
}

extension ModifierLatchActivity on ModifierLatch {
  bool get isActive => this != ModifierLatch.off;

  String tooltip(String label) {
    return switch (this) {
      ModifierLatch.off => label,
      ModifierLatch.once => '$label, next key',
      ModifierLatch.locked => '$label, locked',
    };
  }
}

/// The line above the keys: "CTRL armed", "CTRL locked", or nothing.
String modifierHint(ModifierLatch ctrl, ModifierLatch alt) {
  String? part(String label, ModifierLatch latch) => switch (latch) {
    ModifierLatch.off => null,
    ModifierLatch.once => '$label armed',
    ModifierLatch.locked => '$label locked',
  };
  return [part('CTRL', ctrl), part('ALT', alt)].whereType<String>().join(' · ');
}

/// One key on the bar.
sealed class BarKey {
  const BarKey(this.label);

  final String label;
}

class SendKey extends BarKey {
  const SendKey(super.label, this.key, {this.icon});

  final TerminalKey key;
  final IconData? icon;
}

class TextKey extends BarKey {
  const TextKey(super.label);
}

class CtrlKey extends BarKey {
  const CtrlKey() : super('CTRL');
}

class AltKey extends BarKey {
  const AltKey() : super('ALT');
}

class PasteKey extends BarKey {
  const PasteKey() : super('Paste');
}

class SnippetsKey extends BarKey {
  const SnippetsKey() : super('Snippets');
}

/// Page 1, then page 2, each two rows of eight keys.
const keyBarRows = <List<BarKey>>[
  [
    SendKey('ESC', TerminalKey.escape),
    SendKey('TAB', TerminalKey.tab),
    CtrlKey(),
    AltKey(),
    TextKey('|'),
    TextKey('~'),
    TextKey('/'),
    TextKey('-'),
  ],
  [
    SendKey('Home', TerminalKey.home),
    SendKey('End', TerminalKey.end),
    SendKey('PgUp', TerminalKey.pageUp),
    SendKey('PgDn', TerminalKey.pageDown),
    SendKey('Left', TerminalKey.arrowLeft, icon: Icons.arrow_back),
    SendKey('Up', TerminalKey.arrowUp, icon: Icons.arrow_upward),
    SendKey('Down', TerminalKey.arrowDown, icon: Icons.arrow_downward),
    SendKey('Right', TerminalKey.arrowRight, icon: Icons.arrow_forward),
  ],
  [
    SendKey('F1', TerminalKey.f1),
    SendKey('F2', TerminalKey.f2),
    SendKey('F3', TerminalKey.f3),
    SendKey('F4', TerminalKey.f4),
    SendKey('F5', TerminalKey.f5),
    SendKey('F6', TerminalKey.f6),
    SendKey('F7', TerminalKey.f7),
    SendKey('F8', TerminalKey.f8),
  ],
  [
    SendKey('F9', TerminalKey.f9),
    SendKey('F10', TerminalKey.f10),
    SendKey('F11', TerminalKey.f11),
    SendKey('F12', TerminalKey.f12),
    SendKey('Ins', TerminalKey.insert),
    SendKey('Del', TerminalKey.delete),
    PasteKey(),
    SnippetsKey(),
  ],
];

/// The rows on each page: two per page, or one per page in [KeyBarLayout.oneRow].
List<List<List<BarKey>>> keyBarPages(KeyBarLayout layout) {
  return switch (layout) {
    KeyBarLayout.twoRows => [
      [keyBarRows[0], keyBarRows[1]],
      [keyBarRows[2], keyBarRows[3]],
    ],
    KeyBarLayout.oneRow => [for (final row in keyBarRows) [row]],
  };
}

/// Keys that are awkward to reach on a phone keyboard, in swipeable pages.
class TerminalKeyboardBar extends StatefulWidget {
  const TerminalKeyboardBar({
    super.key,
    required this.onKey,
    required this.onText,
    required this.ctrl,
    required this.alt,
    required this.onToggleCtrl,
    required this.onToggleAlt,
    required this.onPaste,
    this.onSnippets,
    this.layout = KeyBarLayout.twoRows,
    this.haptics = true,
  });

  final void Function(TerminalKey key) onKey;
  final void Function(String text) onText;
  final ModifierLatch ctrl;
  final ModifierLatch alt;
  final VoidCallback onToggleCtrl;
  final VoidCallback onToggleAlt;

  /// Pastes the clipboard into the terminal.
  final VoidCallback onPaste;
  final VoidCallback? onSnippets;
  final KeyBarLayout layout;
  final bool haptics;

  @override
  State<TerminalKeyboardBar> createState() => _TerminalKeyboardBarState();
}

class _TerminalKeyboardBarState extends State<TerminalKeyboardBar> {
  final _pages = PageController();
  var _page = 0;

  @override
  void didUpdateWidget(TerminalKeyboardBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.layout != widget.layout && _pages.hasClients) {
      _pages.jumpToPage(0);
      _page = 0;
    }
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _press(BarKey key) {
    if (widget.haptics) {
      HapticFeedback.selectionClick();
    }
    switch (key) {
      case SendKey(:final key):
        widget.onKey(key);
      case TextKey(:final label):
        widget.onText(label);
      case CtrlKey():
        widget.onToggleCtrl();
      case AltKey():
        widget.onToggleAlt();
      case PasteKey():
        widget.onPaste();
      case SnippetsKey():
        widget.onSnippets?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = keyBarPages(widget.layout);
    final rows = pages.first.length;
    const gap = 6.0;
    final height = rows * AppSizes.key + (rows - 1) * gap;
    final hint = modifierHint(widget.ctrl, widget.alt);
    return Material(
      color: AppColors.bar,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 22,
                child: Row(
                  children: [
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        hint,
                        key: const ValueKey('modifier-hint'),
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.accent,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                    for (var i = 0; i < pages.length; i++)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _pages.animateToPage(
                          i,
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOut,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 3,
                            vertical: 7,
                          ),
                          child: Container(
                            width: i == _page ? 14 : 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: i == _page
                                  ? AppColors.accent
                                  : AppColors.borderStrong,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
              SizedBox(
                height: height,
                child: PageView(
                  controller: _pages,
                  onPageChanged: (page) => setState(() => _page = page),
                  children: [
                    for (final page in pages)
                      Column(
                        children: [
                          for (var r = 0; r < page.length; r++) ...[
                            if (r > 0) const SizedBox(height: gap),
                            Row(
                              children: [
                                for (var k = 0; k < page[r].length; k++) ...[
                                  if (k > 0) const SizedBox(width: 4),
                                  Expanded(child: _keyFor(page[r][k])),
                                ],
                              ],
                            ),
                          ],
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _keyFor(BarKey key) {
    return switch (key) {
      CtrlKey() => _ModifierKey(
        label: key.label,
        latch: widget.ctrl,
        onPressed: () => _press(key),
      ),
      AltKey() => _ModifierKey(
        label: key.label,
        latch: widget.alt,
        onPressed: () => _press(key),
      ),
      SendKey(:final icon?) => _Key(
        icon: icon,
        tooltip: key.label,
        onPressed: () => _press(key),
      ),
      PasteKey() => _Key(
        icon: Icons.content_paste,
        tooltip: 'Paste',
        onPressed: () => _press(key),
      ),
      SnippetsKey() => _Key(
        icon: Icons.code,
        tooltip: 'Snippets',
        onPressed: () => _press(key),
      ),
      _ => _Key(label: key.label, onPressed: () => _press(key)),
    };
  }
}

class _Key extends StatelessWidget {
  const _Key({this.label, this.icon, this.tooltip, required this.onPressed});

  final String? label;
  final IconData? icon;
  final String? tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final text = label;
    final key = _KeyFace(
      background: AppColors.surface,
      border: AppColors.border,
      onPressed: onPressed,
      child: text != null
          ? Text(
              text,
              maxLines: 1,
              style: TextStyle(
                fontFamily: AppFonts.mono,
                fontSize: text.length > 3 ? 12 : 14,
                color: AppColors.text,
              ),
            )
          : Icon(icon, size: 18, color: AppColors.text),
    );
    final tip = tooltip;
    return tip == null ? key : Tooltip(message: tip, child: key);
  }
}

class _ModifierKey extends StatelessWidget {
  const _ModifierKey({
    required this.label,
    required this.latch,
    required this.onPressed,
  });

  final String label;
  final ModifierLatch latch;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final (background, border, foreground) = switch (latch) {
      ModifierLatch.off => (AppColors.surface, AppColors.border, AppColors.text),
      ModifierLatch.once => (
        AppColors.accentSoft,
        AppColors.accent,
        AppColors.accent,
      ),
      ModifierLatch.locked => (
        AppColors.accent,
        AppColors.accent,
        AppColors.onAccent,
      ),
    };
    return Tooltip(
      message: latch.tooltip(label),
      child: _KeyFace(
        background: background,
        border: border,
        onPressed: onPressed,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontFamily: AppFonts.mono,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: foreground,
              ),
            ),
            if (latch == ModifierLatch.locked) ...[
              const SizedBox(width: 2),
              Icon(Icons.lock, size: 11, color: foreground, semanticLabel: 'locked'),
            ],
          ],
        ),
      ),
    );
  }
}

class _KeyFace extends StatelessWidget {
  const _KeyFace({
    required this.background,
    required this.border,
    required this.onPressed,
    required this.child,
  });

  final Color background;
  final Color border;
  final VoidCallback onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: AppSizes.key,
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.key),
          side: BorderSide(color: border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Center(child: FittedBox(fit: BoxFit.scaleDown, child: child)),
        ),
      ),
    );
  }
}
