import 'package:flutter/material.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';
import 'package:ssh_app/services/ssh/ssh_errors.dart';
import 'package:ssh_app/theme/tokens.dart';

/// The five steps the progress bar shows, in order.
const connectionSteps = [
  SSHConnectionStage.loadingCredentials,
  SSHConnectionStage.openingConnection,
  SSHConnectionStage.exchangingKeys,
  SSHConnectionStage.verifyingHostKey,
  SSHConnectionStage.authenticating,
];

/// One plain sentence for a failed connection. The full text is in the log.
String plainConnectionError(
  SSHConnectionException? error,
  ServerConfig server, {
  String? fallback,
}) {
  return switch (error) {
    SSHDnsException() => "Couldn't find ${server.host}. Check the host name.",
    SSHConnectionRefusedException() =>
      '${server.host} refused the connection on port ${server.port}.',
    SSHUnreachableException() =>
      "Can't reach ${server.host} from this network.",
    SSHTimeoutException() => "${server.host} didn't answer in time.",
    SSHAuthFailedException() =>
      "The server didn't accept the password or key for ${server.username}.",
    SSHHostKeyChangedException() =>
      "The server's host key has changed. Don't connect until you know why.",
    SSHHostKeyRejectedException() =>
      "You didn't trust the host key, so nothing was sent.",
    SSHCredentialsException() =>
      "Couldn't read the saved password or key for this host.",
    SSHHandshakeException() => 'The SSH handshake with ${server.host} failed.',
    SSHUnexpectedDisconnectException() =>
      'The connection dropped and could not be restored.',
    null => fallback ?? "Couldn't connect.",
  };
}

/// What the card shows for one moment of a connection.
class ConnectionCardModel {
  const ConnectionCardModel({
    required this.title,
    required this.message,
    required this.step,
    this.failed = false,
    this.allDone = false,
  });

  /// Builds the card for [state]. [shellError] is set when the shell failed
  /// to open after sign-in; [openingShell] while it is opening.
  factory ConnectionCardModel.from({
    required SSHConnectionState state,
    required ServerConfig server,
    String? shellError,
    bool openingShell = false,
    bool wasConnected = false,
  }) {
    switch (state.status) {
      case SSHConnectionStatus.connecting:
      case SSHConnectionStatus.awaitingHostKeyConfirmation:
        final stage = state.stage ?? SSHConnectionStage.loadingCredentials;
        return ConnectionCardModel(
          title: 'Connecting to ${server.label}',
          message: '${stage.label}...',
          step: connectionSteps.indexOf(stage),
        );
      case SSHConnectionStatus.reconnecting:
        final stage = state.stage;
        return ConnectionCardModel(
          title: 'Connection lost',
          message: state.waitingFor != null
              ? 'Waiting for ${state.waitingFor} to reconnect.'
              : 'Reconnecting (attempt ${state.reconnectAttempt} of '
                    '${state.maxReconnectAttempts})...',
          step: stage == null ? 0 : connectionSteps.indexOf(stage),
        );
      case SSHConnectionStatus.error:
        final stage = state.stage;
        return ConnectionCardModel(
          title: wasConnected ? 'Connection lost' : "Couldn't connect",
          message: plainConnectionError(
            state.error,
            server,
            fallback: state.errorMessage,
          ),
          step: stage == null ? -1 : connectionSteps.indexOf(stage),
          failed: true,
        );
      case SSHConnectionStatus.connected:
        if (shellError != null) {
          return const ConnectionCardModel(
            title: "Couldn't open a shell",
            message: 'Signed in, but the server did not start a shell.',
            step: 5,
            allDone: true,
            failed: true,
          );
        }
        return const ConnectionCardModel(
          title: 'Signed in',
          message: 'Opening shell...',
          step: 5,
          allDone: true,
        );
      case SSHConnectionStatus.disconnected:
        return const ConnectionCardModel(
          title: 'Disconnected',
          message: 'This session has ended.',
          step: -1,
          failed: true,
        );
    }
  }

  final String title;
  final String message;

  /// Index into [connectionSteps] of the current or failed step; -1 when
  /// none applies, 5 when all are done.
  final int step;
  final bool failed;
  final bool allDone;
}

/// Compact progress and error card shown over the terminal.
class ConnectionCard extends StatelessWidget {
  const ConnectionCard({
    super.key,
    required this.model,
    required this.onCancel,
    required this.onDetails,
    required this.onRetry,
    required this.onEditHost,
  });

  final ConnectionCardModel model;
  final VoidCallback onCancel;
  final VoidCallback onDetails;
  final VoidCallback onRetry;
  final VoidCallback onEditHost;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = model.failed;
    return Material(
      color: AppColors.surface,
      elevation: 8,
      shadowColor: Colors.black,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.card),
        side: BorderSide(
          color: failed ? AppColors.error.withValues(alpha: 0.5) : AppColors.border,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (failed)
                  const Icon(Icons.error_outline, color: AppColors.error, size: 20)
                else
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    model.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _Segments(model: model),
            const SizedBox(height: 10),
            Text(
              model.message,
              key: const ValueKey('connection-card-message'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: failed ? AppColors.text : AppColors.muted,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton(onPressed: onDetails, child: const Text('Details')),
                if (failed) ...[
                  OutlinedButton(
                    onPressed: onEditHost,
                    child: const Text('Edit host'),
                  ),
                  FilledButton(onPressed: onRetry, child: const Text('Retry')),
                ] else
                  OutlinedButton(onPressed: onCancel, child: const Text('Cancel')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Segments extends StatelessWidget {
  const _Segments({required this.model});

  final ConnectionCardModel model;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: model.allDone
          ? 'All connection steps done'
          : 'Step ${model.step + 1} of ${connectionSteps.length}',
      child: Row(
        children: [
          for (var i = 0; i < connectionSteps.length; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Expanded(
              child: Container(
                key: ValueKey('connection-step-$i'),
                height: 4,
                decoration: BoxDecoration(
                  color: _color(i),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color _color(int i) {
    if (model.allDone || i < model.step) {
      return model.failed && model.allDone ? AppColors.error : AppColors.accent;
    }
    if (i == model.step) {
      return model.failed
          ? AppColors.error
          : AppColors.accent.withValues(alpha: 0.45);
    }
    return AppColors.border;
  }
}
