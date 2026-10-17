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
    this.validator,
  });

  final String title;
  final String confirmLabel;
  final String initialText;
  final int? maxLength;
  final String? hint;

  /// Returns a message to show instead of closing, or null if the text is
  /// fine.
  final String? Function(String text)? validator;

  static Future<String?> show(
    BuildContext context, {
    required String title,
    required String confirmLabel,
    String initialText = '',
    int? maxLength,
    String? hint,
    String? Function(String text)? validator,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => TextPromptDialog(
        title: title,
        confirmLabel: confirmLabel,
        initialText: initialText,
        maxLength: maxLength,
        hint: hint,
        validator: validator,
      ),
    );
  }

  @override
  State<TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<TextPromptDialog> {
  late final _controller = TextEditingController(text: widget.initialText);
  String? _error;

  void _submit() {
    final text = _controller.text;
    final problem = widget.validator?.call(text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.of(context).pop(text);
  }

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
        decoration: InputDecoration(hintText: widget.hint, errorText: _error),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}
