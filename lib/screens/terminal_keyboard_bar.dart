import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

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
  final bool ctrl;
  final bool alt;
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
              _ModifierKey(label: 'CTRL', selected: ctrl, onPressed: onToggleCtrl),
              _ModifierKey(label: 'ALT', selected: alt, onPressed: onToggleAlt),
              _KeyButton(label: 'ESC', onPressed: () => onKey(TerminalKey.escape)),
              _KeyButton(label: 'TAB', onPressed: () => onKey(TerminalKey.tab)),
              _KeyButton(label: '|', onPressed: () => onText('|')),
              _KeyButton(label: '~', onPressed: () => onText('~')),
              _KeyButton(label: '/', onPressed: () => onText('/')),
              _KeyButton(label: '-', onPressed: () => onText('-')),
              _KeyButton(icon: Icons.arrow_upward, onPressed: () => onKey(TerminalKey.arrowUp)),
              _KeyButton(icon: Icons.arrow_downward, onPressed: () => onKey(TerminalKey.arrowDown)),
              _KeyButton(icon: Icons.arrow_back, onPressed: () => onKey(TerminalKey.arrowLeft)),
              _KeyButton(icon: Icons.arrow_forward, onPressed: () => onKey(TerminalKey.arrowRight)),
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
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilledButton.tonal(
        style: FilledButton.styleFrom(
          backgroundColor: selected ? scheme.primary : scheme.surfaceContainerHighest,
          foregroundColor: selected ? scheme.onPrimary : scheme.onSurface,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        onPressed: onPressed,
        child: Text(label),
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
