import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ssh_app/services/ssh/connection_log.dart';
import 'package:ssh_app/theme/tokens.dart';

/// The connection log in a bottom sheet: timestamped steps, the exact
/// exception text, and a Copy button.
Future<void> showConnectionLogSheet(
  BuildContext context,
  Widget Function(BuildContext context) builder,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      builder: (context, scroll) => PrimaryScrollController(
        controller: scroll,
        child: builder(context),
      ),
    ),
  );
}

class ConnectionLogView extends StatelessWidget {
  const ConnectionLogView({super.key, required this.entries});

  final List<ConnectionLogEntry> entries;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(
      ClipboardData(text: entries.map((entry) => '$entry').join('\n')),
    );
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Connection log copied')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const mono = TextStyle(
      fontFamily: AppFonts.mono,
      fontSize: 12,
      height: 1.45,
      color: AppColors.text,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text('Connection log', style: theme.textTheme.titleMedium),
              ),
              TextButton.icon(
                onPressed: entries.isEmpty ? null : () => _copy(context),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy'),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            decoration: BoxDecoration(
              color: AppColors.terminalBackground,
              borderRadius: BorderRadius.circular(AppRadii.button),
              border: Border.all(color: AppColors.border),
            ),
            child: entries.isEmpty
                ? Center(
                    child: Text(
                      'Nothing logged yet.',
                      style: mono.copyWith(color: AppColors.muted),
                    ),
                  )
                : ListView.builder(
                    primary: true,
                    padding: const EdgeInsets.all(12),
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      return SelectableText.rich(
                        TextSpan(
                          style: mono,
                          children: [
                            TextSpan(
                              text: '${entry.timestamp}  ',
                              style: const TextStyle(color: AppColors.muted),
                            ),
                            TextSpan(
                              text: entry.message,
                              style: entry.isError
                                  ? const TextStyle(
                                      color: AppColors.error,
                                      fontWeight: FontWeight.w700,
                                    )
                                  : null,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}
