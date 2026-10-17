/// A path from an OSC 7 directory report (`file://host/path`), or null.
String? parseOsc7(String url) {
  if (!url.startsWith('file://')) return null;
  final rest = url.substring('file://'.length);
  final slash = rest.indexOf('/');
  if (slash < 0) return null;
  try {
    return Uri.decodeComponent(rest.substring(slash));
  } on FormatException {
    return rest.substring(slash);
  }
}

/// Reads the prompt marks (OSC 133) and directory reports (OSC 7) a shell
/// with the integration script prints. Feed it xterm's `onPrivateOSC`.
class ShellMarks {
  ShellMarks({
    this.onPromptStart,
    this.onPromptEnd,
    this.onCommandEnd,
    this.onDirectory,
  });

  /// The prompt begins (133;A).
  final void Function()? onPromptStart;

  /// The prompt ended, so what follows is typed input (133;B).
  final void Function()? onPromptEnd;

  /// The last command finished, with its exit code when given (133;D).
  final void Function(int? exitCode)? onCommandEnd;

  /// The shell is now in this directory (OSC 7).
  final void Function(String path)? onDirectory;

  /// Whether the shell has reported anything yet. Until it has, the app does
  /// not know where input starts and falls back to tracking keystrokes.
  bool get active => _active;
  var _active = false;

  /// Handles one OSC. Returns true if it was one of ours.
  bool handle(String code, List<String> args) {
    switch (code) {
      case '133':
        if (args.isEmpty || args.first.isEmpty) return false;
        switch (args.first[0]) {
          case 'A':
            _active = true;
            onPromptStart?.call();
          case 'B':
            _active = true;
            onPromptEnd?.call();
          case 'D':
            _active = true;
            final code = args.length > 1 ? int.tryParse(args[1]) : null;
            onCommandEnd?.call(code);
          case 'C':
            _active = true;
          default:
            return false;
        }
        return true;
      case '7':
        // A ';' inside the path splits it into several arguments.
        final path = parseOsc7(args.join(';'));
        if (path == null) return false;
        _active = true;
        onDirectory?.call(path);
        return true;
    }
    return false;
  }

  /// Forget what was learned, for a new shell.
  void reset() => _active = false;
}
