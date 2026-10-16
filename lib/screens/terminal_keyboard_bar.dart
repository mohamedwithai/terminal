import 'package:flutter/material.dart';
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

/// Touch keys that are awkward to reach on a phone software keyboard.
class TerminalKeyboardBar extends StatelessWidget {
  const TerminalKeyboardBar({
    super.key,
    required this.onKey,
    required this.onText,
    required this.ctrl,
    required this.alt,
    required this.onToggleCtrl,
    required this.onToggleAlt,
  });

  final void Function(TerminalKey key) onKey;
  final void Function(String text) onText;
  final ModifierLatch ctrl;
  final ModifierLatch alt;
  final VoidCallback onToggleCtrl;
  final VoidCallback onToggleAlt;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            children: [
              _ModifierKey(label: 'CTRL', latch: ctrl, onPressed: onToggleCtrl),
              _ModifierKey(label: 'ALT', latch: alt, onPressed: onToggleAlt),
              _KeyButton(
                label: 'ESC',
                onPressed: () => onKey(TerminalKey.escape),
              ),
              _KeyButton(label: 'TAB', onPressed: () => onKey(TerminalKey.tab)),
              _KeyButton(label: '|', onPressed: () => onText('|')),
              _KeyButton(label: '~', onPressed: () => onText('~')),
              _KeyButton(label: '/', onPressed: () => onText('/')),
              _KeyButton(label: '-', onPressed: () => onText('-')),
              _KeyButton(
                icon: Icons.arrow_upward,
                onPressed: () => onKey(TerminalKey.arrowUp),
              ),
              _KeyButton(
                icon: Icons.arrow_downward,
                onPressed: () => onKey(TerminalKey.arrowDown),
              ),
              _KeyButton(
                icon: Icons.arrow_back,
                onPressed: () => onKey(TerminalKey.arrowLeft),
              ),
              _KeyButton(
                icon: Icons.arrow_forward,
                onPressed: () => onKey(TerminalKey.arrowRight),
              ),
            ],
          ),
        ),
      ),
    );
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
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (latch) {
      ModifierLatch.off => (scheme.surfaceContainerHighest, scheme.onSurface),
      ModifierLatch.once => (scheme.primary, scheme.onPrimary),
      ModifierLatch.locked => (scheme.tertiary, scheme.onTertiary),
    };
    return Tooltip(
      message: latch.tooltip(label),
      child: Padding(
        padding: const EdgeInsets.only(right: 6),
        child: FilledButton.tonal(
          style: FilledButton.styleFrom(
            backgroundColor: background,
            foregroundColor: foreground,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
          onPressed: onPressed,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label),
              if (latch == ModifierLatch.locked) ...[
                const SizedBox(width: 4),
                const Icon(Icons.lock, size: 14, semanticLabel: 'locked'),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _KeyButton extends StatelessWidget {
  const _KeyButton({this.label, this.icon, required this.onPressed});

  final String? label;
  final IconData? icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          minimumSize: const Size(40, 36),
        ),
        onPressed: onPressed,
        child: icon == null ? Text(label!) : Icon(icon, size: 18),
      ),
    );
  }
}
