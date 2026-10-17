import 'package:flutter/material.dart';
import 'package:ssh_app/services/autocomplete/completion_engine.dart';
import 'package:ssh_app/theme/tokens.dart';

/// Height of one suggestion row.
const suggestionRowHeight = 46.0;

/// At most this many rows are shown.
const suggestionRows = 4;

/// Completions above the key bar. Tap fills the line; a long press fills it
/// and presses Enter. Fades and slides in and out over 180ms.
class SuggestionPanel extends StatefulWidget {
  const SuggestionPanel({
    super.key,
    required this.suggestions,
    required this.typed,
    required this.onFill,
    required this.onFillAndRun,
  });

  final List<Suggestion> suggestions;

  /// The line being completed, shown in a quieter color in each row.
  final String typed;
  final ValueChanged<Suggestion> onFill;
  final ValueChanged<Suggestion> onFillAndRun;

  @override
  State<SuggestionPanel> createState() => _SuggestionPanelState();
}

class _SuggestionPanelState extends State<SuggestionPanel> {
  /// The last non-empty list, kept while the panel fades out.
  List<Suggestion> _shown = const [];

  @override
  Widget build(BuildContext context) {
    if (widget.suggestions.isNotEmpty) {
      _shown = widget.suggestions.take(suggestionRows).toList();
    }
    final visible = widget.suggestions.isNotEmpty;
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      alignment: Alignment.bottomCenter,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        offset: visible ? Offset.zero : const Offset(0, 0.3),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 180),
          opacity: visible ? 1 : 0,
          // Once faded out there is nothing left to show or keep laid out.
          onEnd: () {
            if (!visible && _shown.isNotEmpty && mounted) {
              setState(() => _shown = const []);
            }
          },
          child: _shown.isEmpty
              ? const SizedBox(width: double.infinity)
              : IgnorePointer(
                  ignoring: !visible,
                  child: Material(
                    color: AppColors.bar,
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        border: Border(
                          top: BorderSide(color: AppColors.border),
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final (i, s) in _shown.indexed)
                            _Row(
                              key: ValueKey('suggestion-$i'),
                              suggestion: s,
                              typed: widget.typed,
                              highlighted: i == 0,
                              onTap: () => widget.onFill(s),
                              onLongPress: () => widget.onFillAndRun(s),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.suggestion,
    required this.typed,
    required this.highlighted,
    required this.onTap,
    required this.onLongPress,
  });

  final Suggestion suggestion;
  final String typed;
  final bool highlighted;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    // For a history or common command the label starts with what was typed.
    final label = suggestion.label;
    final shared =
        suggestion.deleteCount == 0 &&
            suggestion.source != SuggestionSource.path &&
            label.startsWith(typed)
        ? typed.length
        : 0;
    return Material(
      color: highlighted ? AppColors.accentSoft : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: SizedBox(
          height: suggestionRowHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                SizedBox(width: 26, child: Center(child: _icon())),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: label.substring(0, shared),
                              style: const TextStyle(color: AppColors.muted),
                            ),
                            TextSpan(
                              text: label.substring(shared),
                              style: const TextStyle(color: AppColors.text),
                            ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: AppFonts.mono,
                          fontSize: 13.5,
                        ),
                      ),
                      if (suggestion.meta != null)
                        Text(
                          suggestion.meta!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.muted,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _icon() {
    return switch (suggestion.source) {
      SuggestionSource.path => const Icon(
        Icons.folder_outlined,
        size: 18,
        color: AppColors.warn,
        semanticLabel: 'Path',
      ),
      SuggestionSource.history => const Icon(
        Icons.history,
        size: 18,
        color: AppColors.muted,
        semanticLabel: 'History',
      ),
      SuggestionSource.snippet => const Text(
        '>_',
        semanticsLabel: 'Snippet',
        style: TextStyle(
          fontFamily: AppFonts.mono,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: AppColors.accent,
        ),
      ),
      SuggestionSource.common => const Icon(
        Icons.bolt,
        size: 18,
        color: AppColors.muted,
        semanticLabel: 'Common command',
      ),
    };
  }
}
