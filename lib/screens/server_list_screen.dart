import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/screens/server_form_screen.dart';

/// Lists saved servers. Credentials stay in the vault and are not shown.
class ServerListScreen extends ConsumerWidget {
  const ServerListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final servers = ref.watch(serverListProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Servers')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(context),
        icon: const Icon(Icons.add),
        label: const Text('Add server'),
      ),
      body: servers.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _LoadError(
          message: error.toString(),
          onRetry: () => ref.invalidate(serverListProvider),
        ),
        data: (items) {
          if (items.isEmpty) {
            return _EmptyState(onAdd: () => _openForm(context));
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(serverListProvider),
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final server = items[index];
                return _ServerTile(server: server);
              },
            ),
          );
        },
      ),
    );
  }

  void _openForm(BuildContext context, [ServerConfig? server]) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ServerFormScreen(server: server),
      ),
    );
  }
}

class _ServerTile extends ConsumerWidget {
  const _ServerTile({required this.server});

  final ServerConfig server;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Dismissible(
      key: ValueKey(server.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _confirmDelete(context, server.label),
      onDismissed: (_) {
        ref.read(serverListProvider.notifier).delete(server.id);
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(Icons.delete_outline, color: scheme.onErrorContainer),
      ),
      child: Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: CircleAvatar(
            child: Icon(
              server.authType.name == 'privateKey' ? Icons.key : Icons.password,
            ),
          ),
          title: Text(server.label),
          subtitle: Text(
            '${server.username}@${server.host}:${server.port}\n${server.authType.label}',
          ),
          isThreeLine: true,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ServerFormScreen(server: server),
            ),
          ),
          onLongPress: () async {
            final confirmed = await _confirmDelete(context, server.label);
            if (!confirmed || !context.mounted) {
              return;
            }
            await ref.read(serverListProvider.notifier).delete(server.id);
          },
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined, size: 56, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text('No servers yet', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Add a host to store its address here and its password or private key in encrypted storage.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add server'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

Future<bool> _confirmDelete(BuildContext context, String label) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('Delete server?'),
        content: Text(
          'Remove $label and its saved credentials from this device?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}
