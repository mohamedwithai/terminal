import 'dart:async';

import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/services/snippets/snippet_runner.dart';

/// A shell on one host, as the runner sees it.
abstract interface class HostShell {
  /// Everything the shell prints, as text.
  Stream<String> get output;

  void write(String text);

  Future<void> close();
}

/// Opens a shell on [server], or throws [HostRunException] with a message
/// to show the user.
typedef HostShellOpener = Future<HostShell> Function(ServerConfig server);

/// A host could not be reached or signed in to; [message] is safe to show.
class HostRunException implements Exception {
  const HostRunException(this.message);

  final String message;

  @override
  String toString() => message;
}

enum HostRunStatus {
  waiting('Waiting'),
  connecting('Connecting'),
  running('Running'),
  succeeded('Done'),
  failed('Failed'),
  cancelled('Stopped'),
  unreachable('Could not connect');

  const HostRunStatus(this.label);

  final String label;

  bool get isFinished =>
      this == succeeded ||
      this == failed ||
      this == cancelled ||
      this == unreachable;
}

/// Progress and output of one host in a [MultiHostRun].
class HostRun {
  HostRun(this.server, int steps)
    : steps = List.filled(steps, StepStatus.pending);

  final ServerConfig server;
  HostRunStatus status = HostRunStatus.waiting;
  final List<StepStatus> steps;

  /// Why the host could not be used, when it could not.
  String? message;

  final _output = StringBuffer();
  static const _outputLimit = 256 * 1024;

  /// What the host printed, without the hidden exit-code markers.
  String get output => _output.toString();

  int get stepsDone => steps
      .where((s) => s != StepStatus.pending && s != StepStatus.running)
      .length;

  void _append(String text) {
    _output.write(text);
    if (_output.length > _outputLimit) {
      final all = _output.toString();
      _output
        ..clear()
        ..write(all.substring(all.length - _outputLimit ~/ 2));
    }
  }
}

/// Runs the same steps on several hosts at once.
class MultiHostRun {
  MultiHostRun({
    required this.opener,
    required List<ServerConfig> servers,
    required this.steps,
    this.stopOnFailure = false,
  }) : hosts = [for (final server in servers) HostRun(server, steps.length)];

  final HostShellOpener opener;
  final List<RunStep> steps;
  final bool stopOnFailure;
  final List<HostRun> hosts;

  final _changes = StreamController<void>.broadcast();
  final _runners = <HostRun, SnippetRunner>{};
  var _stopped = false;
  Future<void>? _done;

  /// Emits whenever a host's status, steps or output change.
  Stream<void> get changes => _changes.stream;

  bool get isDone => hosts.every((host) => host.status.isFinished);

  bool get succeeded =>
      hosts.every((host) => host.status == HostRunStatus.succeeded);

  int get failedCount => hosts
      .where(
        (host) =>
            host.status == HostRunStatus.failed ||
            host.status == HostRunStatus.unreachable,
      )
      .length;

  /// Completes when every host has finished.
  Future<void> get done => _done ?? Future.value();

  /// Starts every host. Safe to call once.
  Future<void> start() {
    return _done ??= Future.wait([for (final host in hosts) _runHost(host)])
        .then((_) {
          if (!_changes.isClosed) _changes.close();
        });
  }

  /// Stops every host: shells in progress are abandoned and closed.
  void stopAll() {
    _stopped = true;
    for (final runner in _runners.values) {
      runner.cancel();
    }
    for (final host in hosts) {
      if (host.status == HostRunStatus.waiting) {
        host.status = HostRunStatus.cancelled;
      }
    }
    _notify();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> _runHost(HostRun host) async {
    if (_stopped) {
      host.status = HostRunStatus.cancelled;
      _notify();
      return;
    }
    host.status = HostRunStatus.connecting;
    _notify();
    final HostShell shell;
    try {
      shell = await opener(host.server);
    } on HostRunException catch (error) {
      host.status = HostRunStatus.unreachable;
      host.message = error.message;
      _notify();
      return;
    } catch (error) {
      host.status = HostRunStatus.unreachable;
      host.message = "Couldn't connect.";
      _notify();
      return;
    }
    if (_stopped) {
      host.status = HostRunStatus.cancelled;
      _notify();
      await shell.close();
      return;
    }

    final runner = SnippetRunner(write: shell.write);
    _runners[host] = runner;
    final subscription = shell.output.listen((chunk) {
      final shown = runner.feed(chunk);
      if (shown.isNotEmpty) {
        host._append(shown);
        _notify();
      }
    });
    host.status = HostRunStatus.running;
    _notify();
    try {
      final result = await runner.run(
        steps,
        stopOnFailure: stopOnFailure,
        onStep: (index, status) {
          host.steps[index] = status;
          _notify();
        },
      );
      host.status = switch (result.status) {
        RunStatus.succeeded => HostRunStatus.succeeded,
        RunStatus.failed => HostRunStatus.failed,
        RunStatus.cancelled => HostRunStatus.cancelled,
      };
    } finally {
      host._append(runner.flush());
      await subscription.cancel();
      _runners.remove(host);
      await shell.close();
      _notify();
    }
  }
}
