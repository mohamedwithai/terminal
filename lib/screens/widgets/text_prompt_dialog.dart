import 'package:flutter/material.dart';

/// Asks for one line of text. Pops the entered text, or null on Cancel.
///
/// The controller lives in the dialog's own State, so it is disposed only
/// after the closing animation has finished.
class TextPromptDialog extends StatefulWidget {
  const TextPromptDialog({
    super.key,
    required this.title,
    required this.confirmLabel,
    this.initialText = '',
    this.maxLength,
    this.hint,
  });

  final String title;
  final String confirmLabel;
  final String initialText;
  final int? maxLength;
  final String? hint;

  static Future<String?> show(
    BuildContext context, {
    required String title,
    required String confirmLabel,
    String initialText = '',
    int? maxLength,
    String? hint,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => TextPromptDialog(
        title: title,
        confirmLabel: confirmLabel,
        initialText: initialText,
        maxLength: maxLength,
        hint: hint,
      ),
    );
  }

  @override
  State<TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<TextPromptDialog> {
  late final _controller = TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: widget.maxLength,
        decoration: InputDecoration(hintText: widget.hint),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
