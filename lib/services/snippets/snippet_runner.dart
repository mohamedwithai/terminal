import 'dart:async';
import 'dart:math';

import 'package:ssh_app/models/snippet.dart';
import 'package:ssh_app/services/snippets/marker_filter.dart';

/// One step with its variables filled in.
class RunStep {
  const RunStep({
    required this.command,
    this.wait = const WaitRule.prompt(),
    this.timeout = const Duration(seconds: SnippetStep.defaultTimeoutSeconds),
  });

  final String command;
  final WaitRule wait;
  final Duration timeout;
}

enum StepStatus { pending, running, succeeded, failed, timedOut, skipped }

enum RunStatus { succeeded, failed, cancelled }

class RunResult {
  const RunResult(this.status, this.steps, this.exitCodes);

  final RunStatus status;
  final List<StepStatus> steps;

  /// Exit code per step, where the step reported one.
  final Map<int, int> exitCodes;
}

/// Runs steps in one shell, waiting for each as its rule says.
///
/// The owner of the shell passes everything it prints through [feed] and
/// shows what comes back, which is the output without the hidden exit-code
/// marker. Nothing here knows about SSH.
class SnippetRunner {
  SnippetRunner({required this.write, Random? random})
    : _random = random ?? Random.secure() {
    _filter = MarkerFilter(_nonce(), onExitCode: _onExitCode);
  }

  /// Sends text to the shell.
  final void Function(String text) write;
  final Random _random;
  late final MarkerFilter _filter;

  /// Output since the current step began, for "text appears".
  final _recent = StringBuffer();
  static const _recentLimit = 32 * 1024;

  Completer<int>? _exitWaiter;
  Completer<void>? _textWaiter;
  String _textWanted = '';
  var _cancelled = false;
  Completer<void>? _cancelSignal;

  String _nonce() {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(
      6,
      (_) => alphabet[_random.nextInt(alphabet.length)],
    ).join();
  }

  /// Passes one piece of shell output through. Returns what to display.
  String feed(String raw) {
    final shown = _filter.feed(raw);
    if (shown.isNotEmpty) {
      _recent.write(shown);
      if (_recent.length > _recentLimit) {
        final text = _recent.toString();
        _recent
          ..clear()
          ..write(text.substring(text.length - _recentLimit ~/ 2));
      }
      _checkText();
    }
    return shown;
  }

  /// Output held back while it might have been a marker.
  String flush() => _filter.flush();

  void _onExitCode(int code) {
    final waiter = _exitWaiter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(code);
    }
  }

  void _checkText() {
    final waiter = _textWaiter;
    if (waiter == null || waiter.isCompleted) return;
    final text = _recent.toString();
    // Skip the shell's echo of the command, which may contain the text.
    final newline = text.indexOf('\n');
    if (newline >= 0 && text.indexOf(_textWanted, newline) >= 0) {
      waiter.complete();
    }
  }

  /// Stops the run. The step in progress is abandoned and the rest skipped.
  void cancel() {
    _cancelled = true;
    final signal = _cancelSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  /// Runs [steps] in order. [onStep] is told when each begins and ends.
  Future<RunResult> run(
    List<RunStep> steps, {
    bool stopOnFailure = false,
    void Function(int index, StepStatus status)? onStep,
  }) async {
    _cancelled = false;
    _cancelSignal = Completer<void>();
    final statuses = List.filled(steps.length, StepStatus.pending);
    final exitCodes = <int, int>{};
    var failed = false;

    void set(int index, StepStatus status) {
      statuses[index] = status;
      onStep?.call(index, status);
    }

    for (var i = 0; i < steps.length; i++) {
      if (_cancelled || (failed && stopOnFailure)) {
        set(i, StepStatus.skipped);
        continue;
      }
      set(i, StepStatus.running);
      final step = steps[i];
      _recent.clear();
      final outcome = await _runStep(step);
      if (_cancelled) {
        set(i, StepStatus.skipped);
        continue;
      }
      if (outcome.exitCode != null) exitCodes[i] = outcome.exitCode!;
      set(i, outcome.status);
      if (outcome.status != StepStatus.succeeded) failed = true;
    }

    _exitWaiter = null;
    _textWaiter = null;
    final status = _cancelled
        ? RunStatus.cancelled
        : failed
        ? RunStatus.failed
        : RunStatus.succeeded;
    return RunResult(status, statuses, exitCodes);
  }

  Future<({StepStatus status, int? exitCode})> _runStep(RunStep step) async {
    final command = step.command.replaceAll(RegExp(r'[\r\n]+$'), '');
    switch (step.wait.kind) {
      case WaitKind.seconds:
        write('$command\r');
        await _wait<void>(
          Completer<void>(),
          Duration(seconds: step.wait.seconds),
        );
        return (status: StepStatus.succeeded, exitCode: null);
      case WaitKind.text:
        final waiter = Completer<void>();
        _textWaiter = waiter;
        _textWanted = step.wait.text;
        write('$command\r');
        _checkText();
        final done = await _wait<void>(waiter, step.timeout);
        _textWaiter = null;
        return (
          status: done ? StepStatus.succeeded : StepStatus.timedOut,
          exitCode: null,
        );
      case WaitKind.prompt:
        final waiter = Completer<int>();
        _exitWaiter = waiter;
        write('$command${_filter.suffix}\r');
        final done = await _wait<int>(waiter, step.timeout);
        _exitWaiter = null;
        if (!done) return (status: StepStatus.timedOut, exitCode: null);
        final code = await waiter.future;
        return (
          status: code == 0 ? StepStatus.succeeded : StepStatus.failed,
          exitCode: code,
        );
    }
  }

  /// Waits for [waiter], the timeout or a cancel. True if [waiter] finished.
  /// For a plain delay, pass a waiter that never completes.
  Future<bool> _wait<T>(Completer<T> waiter, Duration timeout) async {
    final timer = Completer<void>();
    final handle = Timer(timeout, () {
      if (!timer.isCompleted) timer.complete();
    });
    try {
      final first = await Future.any<int>([
        waiter.future.then((_) => 0),
        timer.future.then((_) => 1),
        _cancelSignal!.future.then((_) => 2),
      ]);
      return first == 0;
    } finally {
      handle.cancel();
    }
  }
}
