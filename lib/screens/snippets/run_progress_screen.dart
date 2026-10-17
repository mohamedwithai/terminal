import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/providers/snippet_run_providers.dart';
import 'package:ssh_app/screens/widgets/host_avatar.dart';
import 'package:ssh_app/services/snippets/multi_host_run.dart';
import 'package:ssh_app/services/snippets/plain_text.dart';
import 'package:ssh_app/services/snippets/snippet_runner.dart';
import 'package:ssh_app/theme/tokens.dart';

/// Progress and output of a snippet running on several hosts.
class RunProgressScreen extends ConsumerWidget {
  const RunProgressScreen({super.key, required this.entry});

  final RunEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = entry.run;
    return StreamBuilder<void>(
      stream: run.changes,
      builder: (context, _) {
        final done = run.isDone;
        final finished = run.hosts.where((h) => h.status.isFinished).length;
        return Scaffold(
          appBar: AppBar(
            title: Text(entry.snippetName),
            actions: [
              if (!done)
                TextButton.icon(
                  onPressed: run.stopAll,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Stop all'),
                  style: TextButton.styleFrom(foregroundColor: AppColors.error),
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              _Summary(run: run, finished: finished),
              const SizedBox(height: 12),
              for (final host in run.hosts)
                _HostCard(host: host, stepCount: run.steps.length),
              if (!done)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'It keeps running if you leave this screen or switch apps.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.run, required this.finished});

  final MultiHostRun run;
  final int finished;

  @override
  Widget build(BuildContext context) {
    final total = run.hosts.length;
    final done = run.isDone;
    final failed = run.failedCount;
    final (color, text, icon) = !done
        ? (AppColors.warn, '$finished of $total hosts finished', Icons.sync)
        : run.succeeded
        ? (AppColors.accent, 'Done on all $total hosts', Icons.check_circle)
        : (
            AppColors.error,
            failed > 0
                ? '$failed of $total hosts failed'
                : 'Stopped before every host finished',
            Icons.error_outline,
          );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(child: Text(text, key: const ValueKey('run-summary'))),
        ],
      ),
    );
  }
}

class _HostCard extends StatelessWidget {
  const _HostCard({required this.host, required this.stepCount});

  final HostRun host;
  final int stepCount;

  Color get _color => switch (host.status) {
    HostRunStatus.succeeded => AppColors.accent,
    HostRunStatus.failed || HostRunStatus.unreachable => AppColors.error,
    HostRunStatus.cancelled => AppColors.muted,
    HostRunStatus.running || HostRunStatus.connecting => AppColors.warn,
    HostRunStatus.waiting => AppColors.muted,
  };

  @override
  Widget build(BuildContext context) {
    final output = toPlainText(host.output);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Theme(
          data: theme.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: ValueKey('run-host-${host.server.id}'),
            leading: HostAvatar(server: host.server),
            title: Text(host.server.label),
            subtitle: Row(
              children: [
                StatusDot(color: _color),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    host.message ??
                        '${host.status.label}${host.status == HostRunStatus.running ? ' · step ${host.stepsDone + 1} of $stepCount' : ''}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  for (final step in host.steps)
                    Expanded(
                      child: Container(
                        height: 4,
                        margin: const EdgeInsets.only(right: 3),
                        decoration: BoxDecoration(
                          color: switch (step) {
                            StepStatus.succeeded => AppColors.accent,
                            StepStatus.failed ||
                            StepStatus.timedOut => AppColors.error,
                            StepStatus.running => AppColors.warn,
                            _ => AppColors.border,
                          },
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                constraints: const BoxConstraints(maxHeight: 280),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.terminalBackground,
                  borderRadius: BorderRadius.circular(AppRadii.key),
                ),
                child: SingleChildScrollView(
                  reverse: true,
                  child: SelectableText(
                    output.isEmpty ? 'No output yet.' : output,
                    key: ValueKey('run-output-${host.server.id}'),
                    style: TextStyle(
                      fontFamily: AppFonts.mono,
                      fontSize: 12,
                      color: output.isEmpty ? AppColors.muted : AppColors.text,
                    ),
                  ),
                ),
              ),
              if (output.isNotEmpty)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: output));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Output copied')),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy output'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
