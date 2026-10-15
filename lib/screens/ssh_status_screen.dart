import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/providers/ssh_providers.dart';
import 'package:ssh_app/screens/terminal_screen.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';
import 'package:uuid/uuid.dart';

/// Phase 2 status screen: manages connection lifecycle, host key confirmation, and test command execution.
class SSHStatusScreen extends ConsumerStatefulWidget {
  const SSHStatusScreen({super.key, required this.server});

  final ServerConfig server;

  @override
  ConsumerState<SSHStatusScreen> createState() => _SSHStatusScreenState();
}

class _SSHStatusScreenState extends ConsumerState<SSHStatusScreen> {
  late final String _sessionId;
  bool _hasPromptedHostKey = false;
  bool _openedTerminal = false;

  @override
  void initState() {
    super.initState();
    _sessionId = const Uuid().v4();
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
      _hasPromptedHostKey = false;
      _openedTerminal = false;
    });
    try {
      await ref.read(sshSessionControllerProvider(_args)).connect();
    } catch (_) {
      // Errors are surfaced through the state stream
    }
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

  Future<void> _showHostKeyDialog(HostKeyChallenge challenge) async {
    if (_hasPromptedHostKey) return;
    _hasPromptedHostKey = true;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          icon: const Icon(Icons.security, size: 36),
          title: const Text('Authenticity of host can\'t be established'),
          content: Column(
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
              const Text('Are you sure you want to continue connecting and save this key?'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Reject'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Accept & Save'),
            ),
          ],
        );
      },
    );

    if (result == true) {
      challenge.accept();
    } else {
      challenge.reject();
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

    final asyncState = ref.watch(sshSessionStateProvider(_args));
    final state = asyncState.asData?.value ?? const SSHConnectionState.connecting();

    ref.listen(sshSessionStateProvider(_args), (previous, next) {
      final status = next.asData?.value.status;
      if (status == SSHConnectionStatus.connected && !_openedTerminal) {
        _openedTerminal = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _openTerminal();
          }
        });
      }
    });

    // Check if host key confirmation challenge is awaiting
    if (state.status == SSHConnectionStatus.awaitingHostKeyConfirmation &&
        state.challenge != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showHostKeyDialog(state.challenge!);
      });
    }

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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
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
                      _StatusChip(state: state),
                    ],
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
                      'Connection dropped unexpectedly. Reconnecting (attempt ${state.reconnectAttempt} of ${state.maxReconnectAttempts})...',
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Error card
          if (state.status == SSHConnectionStatus.error) ...[
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
                        Text(
                          'Connection Error',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: scheme.onErrorContainer,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      state.errorMessage ?? 'Unknown error occurred.',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        color: scheme.onErrorContainer,
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _connect,
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
          if (state.isConnected) ...[
            FilledButton.icon(
              onPressed: _openTerminal,
              icon: const Icon(Icons.terminal),
              label: const Text('Open terminal'),
            ),
          ],

          // Disconnected state
          if (state.status == SSHConnectionStatus.disconnected) ...[
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
          ],
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.state});

  final SSHConnectionState state;

  @override
  Widget build(BuildContext context) {
    final (color, label, icon) = switch (state.status) {
      SSHConnectionStatus.connected => (
          Colors.green,
          'Connected',
          Icons.check_circle_outline
        ),
      SSHConnectionStatus.connecting => (
          Colors.blue,
          'Connecting...',
          Icons.hourglass_empty
        ),
      SSHConnectionStatus.awaitingHostKeyConfirmation => (
          Colors.amber,
          'Verifying Host',
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
