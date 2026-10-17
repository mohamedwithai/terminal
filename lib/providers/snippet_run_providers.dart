import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/snippet.dart';
import 'package:ssh_app/providers/session_keeper_providers.dart';
import 'package:ssh_app/providers/ssh_providers.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/services/snippets/multi_host_run.dart';
import 'package:ssh_app/services/snippets/snippet_runner.dart';
import 'package:ssh_app/services/snippets/ssh_host_shell.dart';

/// How snippet shells are opened. Tests replace this with fakes.
final hostShellOpenerProvider = Provider<HostShellOpener>((ref) {
  final opener = SshHostShellOpener(
    connections: ref.watch(sshConnectionServiceProvider),
    vault: ref.watch(vaultServiceProvider),
  );
  return opener.open;
});

/// A multi-host run and what it was.
class RunEntry {
  RunEntry({
    required this.snippetName,
    required this.run,
    required this.startedAt,
  });

  final String snippetName;
  final MultiHostRun run;
  final DateTime startedAt;
}

final snippetRunsProvider =
    NotifierProvider<SnippetRunsNotifier, List<RunEntry>>(
      SnippetRunsNotifier.new,
    );

/// Runs on several hosts. They live here, not in a screen, so they go on
/// when the user leaves the screen, and the app notifies when one finishes
/// in the background.
class SnippetRunsNotifier extends Notifier<List<RunEntry>> {
  @override
  List<RunEntry> build() => const [];

  RunEntry start({
    required Snippet snippet,
    required List<ServerConfig> hosts,
    required Map<String, String> values,
  }) {
    final steps = [
      for (final step in snippet.resolvedSteps(values))
        RunStep(
          command: step.command,
          wait: step.wait,
          timeout: Duration(seconds: step.timeoutSeconds),
        ),
    ];
    final run = MultiHostRun(
      opener: ref.read(hostShellOpenerProvider),
      servers: hosts,
      steps: steps,
      stopOnFailure: snippet.stopOnFailure,
    );
    final entry = RunEntry(
      snippetName: snippet.name,
      run: run,
      startedAt: ref.read(clockProvider)(),
    );
    state = [entry, ...state];
    final foreground = ref.read(sessionForegroundServiceProvider);
    run.start().then((_) {
      final inBackground =
          WidgetsBinding.instance.lifecycleState != null &&
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
      if (inBackground) {
        final failed = run.failedCount;
        foreground.notify(
          '${snippet.name} finished',
          failed == 0
              ? 'Done on ${hosts.length} host${hosts.length == 1 ? '' : 's'}.'
              : '$failed of ${hosts.length} host${hosts.length == 1 ? '' : 's'} failed.',
        );
      }
    });
    return entry;
  }

  void remove(RunEntry entry) {
    entry.run.stopAll();
    state = [
      for (final e in state)
        if (!identical(e, entry)) e,
    ];
  }

  void clearFinished() {
    state = [
      for (final e in state)
        if (!e.run.isDone) e,
    ];
  }
}
