import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/providers/ssh_providers.dart';
import 'package:ssh_app/screens/terminal_screen.dart';
import 'package:ssh_app/services/ssh/connection_log.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';
import 'package:ssh_app/services/ssh/ssh_errors.dart';
import 'package:uuid/uuid.dart';

/// Connects to a server step by step, asks about unknown host keys, opens
/// the shell, then hands over to the terminal.
class SSHStatusScreen extends ConsumerStatefulWidget {
  const SSHStatusScreen({super.key, required this.server, this.sessionId});

  final ServerConfig server;

  /// Fixed session ID for tests. A new one is generated when null.
  final String? sessionId;

  @override
  ConsumerState<SSHStatusScreen> createState() => _SSHStatusScreenState();
}

class _SSHStatusScreenState extends ConsumerState<SSHStatusScreen> {
  late final String _sessionId;
  HostKeyChallenge? _shownChallenge;
  bool _shellRequested = false;
  bool _shellOpening = false;
  bool _shellOpen = false;
  String? _shellError;

  /// Failure that did not come through the state stream.
  String? _startError;

  @override
  void initState() {
    super.initState();
    _sessionId = widget.sessionId ?? const Uuid().v4();
    if (!kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _connect();
      });
    }
  }

  ({String sessionId, ServerConfig server}) get _args =>
      (sessionId: _sessionId, server: widget.server);

  Future<void> _connect() async {
    setState(() {
      _shownChallenge = null;
      _shellRequested = false;
      _shellOpening = false;
      _shellOpen = false;
      _shellError = null;
      _startError = null;
    });
    try {
      await ref.read(sshSessionControllerProvider(_args)).connect();
    } on SSHConnectionException {
      // Shown through the state stream and the connection log.
    } catch (error) {
      if (mounted) {
        setState(() => _startError = '$error');
      }
    }
  }

  Future<void> _openShellAndTerminal() async {
    setState(() {
      _shellOpening = true;
      _shellError = null;
    });
    try {
      await ref.read(sshSessionControllerProvider(_args)).openShell();
    } catch (error) {
      if (mounted) {
        setState(() {
          _shellOpening = false;
          _shellError = '$error';
        });
      }
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _shellOpening = false;
      _shellOpen = true;
    });
    _openTerminal();
  }

  void _openTerminal() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TerminalScreen(
          server: widget.server,
          sessionId: _sessionId,
        ),
      ),
    );
  }

  void _retry(SSHConnectionState state) {
    if (state.isConnected && _shellError != null) {
      _openShellAndTerminal();
    } else {
      _connect();
    }
  }

  Future<void> _showHostKeyDialog(HostKeyChallenge challenge) async {
    if (identical(_shownChallenge, challenge) || challenge.isCompleted) {
      return;
    }
    _shownChallenge = challenge;

    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => HostKeyDialog(challenge: challenge),
    );
    // Back button or the attempt ending: anything but Accept is a reject.
    challenge.reject();
  }

  void _onStateChanged(SSHConnectionState state) {
    if (state.status == SSHConnectionStatus.awaitingHostKeyConfirmation &&
        state.challenge != null) {
      _showHostKeyDialog(state.challenge!);
    }
    if (state.status == SSHConnectionStatus.connected && !_shellRequested) {
      _shellRequested = true;
      _openShellAndTerminal();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (kIsWeb) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.server.label)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Card(
              color: scheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.public_off, size: 48, color: scheme.error),
                    const SizedBox(height: 16),
                    Text(
                      'SSH Not Supported on Web',
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Web browsers do not permit raw TCP sockets necessary for SSH communication. '
                      'Please run the app on Windows, macOS, Linux, Android, or iOS to connect.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Go back'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    ref.listen(sshSessionStateProvider(_args), (previous, next) {
      final state = next.asData?.value;
      if (state != null) {
        _onStateChanged(state);
      }
    });

    final asyncState = ref.watch(sshSessionStateProvider(_args));
    final state = asyncState.asData?.value ??
        const SSHConnectionState.connecting(
          SSHConnectionStage.loadingCredentials,
        );
    final logEntries =
        ref.watch(sshSessionLogProvider(_args)).asData?.value ?? const [];

    final errorMessage = _startError ??
        (asyncState.hasError ? '${asyncState.error}' : null) ??
        (state.hasError ? state.errorMessage ?? 'Unknown error.' : null) ??
        (state.isConnected ? _shellError : null);
    final progress = _progress(state, failed: errorMessage != null);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.server.label),
        actions: [
          if (state.isConnected)
            IconButton(
              tooltip: 'Disconnect',
              icon: const Icon(Icons.power_settings_new),
              onPressed: () async {
                await ref.read(sshSessionControllerProvider(_args)).disconnect();
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Connection details card
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  CircleAvatar(
                    child: Icon(
                      widget.server.authType.name == 'privateKey'
                          ? Icons.key
                          : Icons.password,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.server.label,
                            style: theme.textTheme.titleMedium),
                        Text(
                          '${widget.server.username}@${widget.server.host}:${widget.server.port}',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  _StatusChip(
                    state: state,
                    failed: errorMessage != null,
                    stage: progress.stage,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Reconnecting alert
          if (state.status == SSHConnectionStatus.reconnecting) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.15),
                border: Border.all(color: Colors.amber),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      state.waitingFor != null
                          ? 'Connection dropped. Waiting for ${state.waitingFor} to reconnect.'
                          : 'Connection dropped unexpectedly. Reconnecting (attempt ${state.reconnectAttempt} of ${state.maxReconnectAttempts})...',
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          if (progress.stage != null || progress.allDone) ...[
            _StageList(progress: progress),
            const SizedBox(height: 16),
          ],

          // Error card
          if (errorMessage != null) ...[
            Card(
              color: scheme.errorContainer,
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.error_outline, color: scheme.onErrorContainer),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            progress.stage == null
                                ? 'Connection Error'
                                : 'Failed: ${progress.stage!.label}',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: scheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      errorMessage,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        color: scheme.onErrorContainer,
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () => _retry(state),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try Again'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Connected actions card
          if (state.isConnected && _shellOpen) ...[
            FilledButton.icon(
              onPressed: _openTerminal,
              icon: const Icon(Icons.terminal),
              label: const Text('Open terminal'),
            ),
            const SizedBox(height: 16),
          ],

          // Disconnected state
          if (state.status == SSHConnectionStatus.disconnected &&
              errorMessage == null) ...[
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  children: [
                    const Icon(Icons.link_off, size: 48, color: Colors.grey),
                    const SizedBox(height: 8),
                    const Text('Disconnected'),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _connect,
                      child: const Text('Connect'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          ConnectionLogPanel(entries: logEntries),
        ],
      ),
    );
  }

  /// Which stage to highlight. The shell stage lives here rather than in
  /// the session, because this screen is what opens the shell.
  _Progress _progress(SSHConnectionState state, {required bool failed}) {
    switch (state.status) {
      case SSHConnectionStatus.connecting:
      case SSHConnectionStatus.reconnecting:
      case SSHConnectionStatus.awaitingHostKeyConfirmation:
        return _Progress(state.stage, failed: failed);
      case SSHConnectionStatus.error:
        return _Progress(state.stage, failed: true);
      case SSHConnectionStatus.connected:
        if (_shellOpen && !_shellOpening) {
          return const _Progress(null, allDone: true);
        }
        return _Progress(
          SSHConnectionStage.openingShell,
          failed: _shellError != null,
        );
      case SSHConnectionStatus.disconnected:
        return const _Progress(null);
    }
  }
}

class _Progress {
  const _Progress(this.stage, {this.failed = false, this.allDone = false});

  /// Current stage, or the stage that failed.
  final SSHConnectionStage? stage;
  final bool failed;
  final bool allDone;
}

/// The connection steps, with the current one highlighted.
class _StageList extends StatelessWidget {
  const _StageList({required this.progress});

  final _Progress progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = progress.stage;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            for (final stage in SSHConnectionStage.values)
              Builder(builder: (context) {
                final isCurrent = stage == current;
                final isDone = progress.allDone ||
                    (current != null && stage.index < current.index);
                final Widget icon;
                final Color? color;
                if (isCurrent && progress.failed) {
                  icon = Icon(Icons.cancel, color: scheme.error, size: 20);
                  color = scheme.error;
                } else if (isCurrent) {
                  icon = const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  );
                  color = scheme.primary;
                } else if (isDone) {
                  icon = const Icon(Icons.check_circle,
                      color: Colors.green, size: 20);
                  color = null;
                } else {
                  icon = Icon(Icons.radio_button_unchecked,
                      color: scheme.outline, size: 20);
                  color = scheme.outline;
                }
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      SizedBox.square(
                        dimension: 22,
                        child: Center(child: icon),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          stage.label,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: color,
                            fontWeight: isCurrent ? FontWeight.bold : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}

/// Asks the user to accept or reject an unknown host key.
///
/// Closes itself if the challenge is decided elsewhere, for example when the
/// connection attempt times out while it is open.
class HostKeyDialog extends StatefulWidget {
  const HostKeyDialog({super.key, required this.challenge});

  final HostKeyChallenge challenge;

  @override
  State<HostKeyDialog> createState() => _HostKeyDialogState();
}

class _HostKeyDialogState extends State<HostKeyDialog> {
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    widget.challenge.decision.then((_) {
      if (mounted && !_closed) {
        _closed = true;
        Navigator.of(context).pop();
      }
    });
  }

  void _decide(bool accept) {
    if (_closed) {
      return;
    }
    _closed = true;
    if (accept) {
      widget.challenge.accept();
    } else {
      widget.challenge.reject();
    }
    Navigator.of(context).pop(accept);
  }

  @override
  Widget build(BuildContext context) {
    final challenge = widget.challenge;
    return AlertDialog(
      icon: const Icon(Icons.security, size: 36),
      title: const Text('Authenticity of host can\'t be established'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Connecting to ${challenge.host}:${challenge.port} for the first time.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Key Type: ${challenge.keyType}',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text('SHA-256 Fingerprint:',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 2),
                  SelectableText(
                    challenge.fingerprint,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Sign-in waits until you choose. Are you sure you want to '
              'continue connecting and save this key?',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _decide(false),
          child: const Text('Reject'),
        ),
        FilledButton(
          onPressed: () => _decide(true),
          child: const Text('Accept & Save'),
        ),
      ],
    );
  }
}

/// Expandable, copyable list of timestamped connection steps.
class ConnectionLogPanel extends StatelessWidget {
  const ConnectionLogPanel({super.key, required this.entries});

  final List<ConnectionLogEntry> entries;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(
      ClipboardData(text: entries.map((entry) => '$entry').join('\n')),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connection log copied')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4);

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: const Icon(Icons.receipt_long),
        title: const Text('Connection log'),
        subtitle: Text(
          entries.length == 1 ? '1 entry' : '${entries.length} entries',
        ),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: entries.isEmpty ? null : () => _copy(context),
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy'),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: entries.isEmpty
                ? Text('Nothing logged yet.', style: mono.copyWith(color: scheme.outline))
                : SelectableText.rich(
                    TextSpan(
                      style: mono.copyWith(color: scheme.onSurface),
                      children: [
                        for (final (index, entry) in entries.indexed) ...[
                          TextSpan(
                            text: '${entry.timestamp}  ',
                            style: TextStyle(color: scheme.outline),
                          ),
                          TextSpan(
                            text: entry.message,
                            style: entry.isError
                                ? TextStyle(
                                    color: scheme.error,
                                    fontWeight: FontWeight.bold,
                                  )
                                : null,
                          ),
                          if (index < entries.length - 1)
                            const TextSpan(text: '\n'),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.state,
    required this.failed,
    required this.stage,
  });

  final SSHConnectionState state;
  final bool failed;
  final SSHConnectionStage? stage;

  @override
  Widget build(BuildContext context) {
    final (color, label, icon) = switch (state.status) {
      _ when failed => (Colors.red, 'Error', Icons.error_outline),
      SSHConnectionStatus.connected when stage != null => (
          Colors.blue,
          stage!.label,
          Icons.hourglass_empty
        ),
      SSHConnectionStatus.connected => (
          Colors.green,
          'Connected',
          Icons.check_circle_outline
        ),
      SSHConnectionStatus.connecting => (
          Colors.blue,
          stage?.label ?? 'Connecting...',
          Icons.hourglass_empty
        ),
      SSHConnectionStatus.awaitingHostKeyConfirmation => (
          Colors.amber,
          'Verifying host key',
          Icons.security
        ),
      SSHConnectionStatus.reconnecting => (
          Colors.orange,
          'Reconnecting',
          Icons.sync
        ),
      SSHConnectionStatus.error => (Colors.red, 'Error', Icons.error_outline),
      SSHConnectionStatus.disconnected => (
          Colors.grey,
          'Disconnected',
          Icons.power_off
        ),
    };

    return Chip(
      avatar: Icon(icon, size: 16, color: color),
      label: Text(label, style: TextStyle(color: color, fontSize: 12)),
      side: BorderSide(color: color.withValues(alpha: 0.5)),
      backgroundColor: color.withValues(alpha: 0.1),
    );
  }
}
