import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Pasted text as the terminal sends it.
///
/// Line breaks become CR, which is what Enter sends. The bracketed paste
/// markers are removed: text containing `ESC [201~` would otherwise end the
/// bracket early, and the rest would reach the program as if typed.
String preparePaste(String text) {
  return text
      .replaceAll('\x1b[200~', '')
      .replaceAll('\x1b[201~', '')
      .replaceAll('\r\n', '\r')
      .replaceAll('\n', '\r');
}

/// Whether pasting [text] could run commands: every line break acts as Enter.
bool pasteNeedsConfirmation(String text) {
  return text.contains('\n') || text.contains('\r');
}

/// [text] for showing before it is pasted: control characters are made
/// visible (ESC shows as ␛) and only the first [maxLines] lines are kept.
({String text, int lineCount, int hiddenLines}) pastePreview(
  String text, {
  int maxLines = 20,
}) {
  final lines = text.replaceAll('\r\n', '\n').split(RegExp('[\r\n]'));
  if (lines.length > 1 && lines.last.isEmpty) {
    lines.removeLast();
  }
  final shown = lines.take(maxLines).map(_showControlCharacters).join('\n');
  return (
    text: shown,
    lineCount: lines.length,
    hiddenLines: math.max(lines.length - maxLines, 0),
  );
}

String _showControlCharacters(String line) {
  final out = StringBuffer();
  for (final rune in line.runes) {
    if (rune == 0x09) {
      out.writeCharCode(rune);
    } else if (rune < 0x20) {
      out.writeCharCode(0x2400 + rune);
    } else if (rune == 0x7f) {
      out.write('␡');
    } else {
      out.writeCharCode(rune);
    }
  }
  return out.toString();
}

/// Shows [text] and asks before pasting it. Returns whether to paste.
///
/// [bracketed] is whether the program asked for bracketed paste, in which
/// case line breaks do not run anything on their own.
Future<bool> confirmPaste(
  BuildContext context,
  String text, {
  required bool bracketed,
}) async {
  final preview = pastePreview(text);
  final lines = preview.lineCount == 1
      ? '1 line'
      : '${preview.lineCount} lines';
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      return AlertDialog(
        title: Text('Paste $lines?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              bracketed
                  ? 'The program turned on bracketed paste, so it receives '
                        'this as one block.'
                  : 'Each line break works like pressing Enter, so the shell '
                        'may run these lines as commands.',
            ),
            const SizedBox(height: 12),
            Flexible(
              child: Container(
                width: double.maxFinite,
                constraints: const BoxConstraints(maxHeight: 240),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    key: const ValueKey('paste-preview'),
                    preview.text,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
            if (preview.hiddenLines > 0) ...[
              const SizedBox(height: 8),
              Text(
                preview.hiddenLines == 1
                    ? '... and 1 more line'
                    : '... and ${preview.hiddenLines} more lines',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Paste'),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}
