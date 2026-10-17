import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ssh_app/services/autocomplete/completion_engine.dart';
import 'package:ssh_app/services/autocomplete/history.dart';
import 'package:ssh_app/services/autocomplete/line_tracker.dart';
import 'package:ssh_app/services/autocomplete/shell_marks.dart';
import 'package:xterm/xterm.dart';

/// Works out what is being typed in a terminal, suggests completions, and
/// remembers the commands that were run.
///
/// With the shell integration installed the line is read off the screen,
/// between the end of the prompt and the cursor. Without it the keys sent
/// since the last Enter are followed instead. Nothing is ever sent to the
/// shell except when the user accepts a suggestion, and nothing runs until
/// Enter.
class AutocompleteController extends ChangeNotifier {
  AutocompleteController({
    required this.terminal,
    required this.hostId,
    required this.engine,
    required this.history,
    required this.sources,
    required this.enabled,
    required this.send,
    this.debounce = const Duration(milliseconds: 60),
  }) {
    marks = ShellMarks(
      onPromptEnd: _onPromptEnd,
      onPromptStart: _onPromptStart,
      onCommandEnd: _onCommandEnd,
      onDirectory: (path) => cwd = path,
    );
  }

  final Terminal terminal;
  final String hostId;
  final CompletionEngine engine;
  final CommandHistory history;
  final CompletionSources Function() sources;
  final bool Function() enabled;

  /// Sends text to the shell as if typed.
  final void Function(String text) send;
  final Duration debounce;

  late final ShellMarks marks;
  final _tracker = InputLineTracker();

  /// The shell's working directory, from OSC 7.
  String? cwd;

  List<Suggestion> suggestions = const [];

  /// What is typed right now, when it is known.
  String? line;

  CellAnchor? _promptEnd;
  Timer? _timer;
  var _generation = 0;
  var _disposed = false;

  /// The command typed before Enter, until the shell reports how it ended.
  String? _pending;

  /// A command is running, so input is not at the prompt.
  var _running = false;

  /// The first suggestion that only continues the line, to show as ghost
  /// text after the cursor.
  Suggestion? get ghost {
    for (final s in suggestions) {
      if (s.deleteCount == 0) return s;
    }
    return null;
  }

  /// Feed xterm's `onPrivateOSC`.
  void handleOsc(String code, List<String> args) => marks.handle(code, args);

  void _onPromptStart() {
    _running = false;
  }

  void _onPromptEnd() {
    _running = false;
    _promptEnd?.dispose();
    final buffer = terminal.buffer;
    final y = buffer.absoluteCursorY;
    if (y < 0 || y >= buffer.lines.length) return;
    _promptEnd = buffer.createAnchor(buffer.cursorX, y);
    _tracker.reset();
    _schedule();
  }

  void _onCommandEnd(int? exitCode) {
    final command = _pending;
    _pending = null;
    if (command != null && (exitCode == null || exitCode == 0)) {
      unawaited(history.record(hostId, command));
    }
    _running = false;
  }

  /// Everything the terminal sends to the shell passes through here first.
  void onInput(String data) {
    final enterPressed = data.contains('\r') || data.contains('\n');
    final secret = _looksLikeSecretPrompt();
    if (marks.active) {
      if (enterPressed && !secret && !_running) {
        final typed = currentLine();
        if (typed != null && typed.trim().isNotEmpty) {
          _pending = typed;
        }
      }
      if (enterPressed) _running = true;
      _tracker.feed(data);
    } else {
      final submitted = _tracker.feed(data);
      if (!secret) {
        for (final command in submitted) {
          if (command != null) unawaited(history.record(hostId, command));
        }
      }
    }
    _schedule();
  }

  /// Call whenever the terminal's content or cursor changed.
  void onTerminalChanged() => _schedule();

  void _schedule() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(debounce, _refresh);
  }

  /// The line being typed: read off the screen when the shell marks its
  /// prompt, else from the tracked keys. Null when not known, when a command
  /// is running, in a full-screen program, or when the cursor is not at the
  /// end of the line.
  String? currentLine() {
    if (terminal.isUsingAltBuffer) return null;
    if (marks.active) {
      final anchor = _promptEnd;
      if (anchor == null || !anchor.attached || _running) return null;
      final buffer = terminal.buffer;
      final start = anchor.offset;
      final endY = buffer.absoluteCursorY;
      final endX = buffer.cursorX;
      if (endY < 0 || endY >= buffer.lines.length) return null;
      if (endY < start.y || (endY == start.y && endX < start.x)) return null;
      // Text after the cursor means it is in the middle of the line.
      final row = buffer.lines[endY];
      if (row.getText(endX, buffer.viewWidth).trim().isNotEmpty) return null;
      final text = buffer.getText(
        BufferRangeLine(start, CellOffset(endX, endY)),
      );
      // A line break means the command already ran.
      return text.contains('\n') ? null : text;
    }
    return _tracker.line;
  }

  /// Whether the cursor is after a prompt asking for a password, where
  /// typing must not be remembered.
  bool _looksLikeSecretPrompt() {
    final buffer = terminal.buffer;
    final y = buffer.absoluteCursorY;
    if (y < 0 || y >= buffer.lines.length) return false;
    final text = buffer.lines[y].getText(0, buffer.cursorX).toLowerCase();
    return RegExp(r'(password|passphrase|passcode|pin)[^:]*:\s*$')
        .hasMatch(text);
  }

  Future<void> _refresh() async {
    if (_disposed) return;
    final generation = ++_generation;
    final typed = enabled() ? currentLine() : null;
    line = typed;
    if (typed == null || typed.trim().isEmpty) {
      _set(const []);
      return;
    }
    final found = await engine.suggest(typed, cwd: cwd, sources: sources());
    if (_disposed || generation != _generation) return;
    _set(found);
  }

  void _set(List<Suggestion> next) {
    String key(List<Suggestion> list) =>
        list.map((s) => '${s.source.index}|${s.label}|${s.insert}').join('\n');
    if (key(next) == key(suggestions)) return;
    suggestions = next;
    notifyListeners();
  }

  /// Types [suggestion] into the shell. With [enter] it is also run, which
  /// only happens on a deliberate long-press.
  void accept(Suggestion suggestion, {bool enter = false}) {
    final backspaces = '\x7f' * suggestion.deleteCount;
    send('$backspaces${suggestion.insert}${enter ? '\r' : ''}');
  }

  /// Accepts the ghost text, if there is one. Returns whether it did.
  bool acceptGhost() {
    final suggestion = ghost;
    if (suggestion == null) return false;
    accept(suggestion);
    return true;
  }

  /// A new shell: forget what was learned about the old one.
  void reset() {
    marks.reset();
    _promptEnd?.dispose();
    _promptEnd = null;
    _tracker.reset();
    _pending = null;
    _running = false;
    cwd = null;
    _set(const []);
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _promptEnd?.dispose();
    super.dispose();
  }
}
