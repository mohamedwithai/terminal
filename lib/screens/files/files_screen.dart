import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/providers/session_tabs_providers.dart';
import 'package:ssh_app/providers/ssh_providers.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/screens/files/sftp_browser_screen.dart';
import 'package:ssh_app/screens/widgets/host_avatar.dart';
import 'package:ssh_app/theme/tokens.dart';

/// The Files tab: pick a host to browse. A host with an open terminal
/// session is browsed over that session's connection.
class FilesScreen extends ConsumerWidget {
  const FilesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hosts = ref.watch(serverListProvider);
    final tabs = ref.watch(sessionTabsProvider).tabs;
    return Scaffold(
      appBar: AppBar(title: const Text('Files')),
      body: hosts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('$error')),
        data: (items) {
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Add a host first, then browse its files here.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'Browse, upload and download files over SFTP.',
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: AppColors.muted),
                ),
              ),
              for (final server in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      key: ValueKey('files-host-${server.id}'),
                      leading: HostAvatar(server: server),
                      title: Text(server.label),
                      subtitle: Text(
                        tabs.any((t) => t.server.id == server.id)
                            ? 'Uses your open session'
                            : '${server.username}@${server.host}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => openFiles(context, ref, server),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Opens the file browser for [server], sharing the connection of its open
/// terminal tab when it has one.
void openFiles(BuildContext context, WidgetRef ref, ServerConfig server) {
  final tab = ref.read(sessionTabsProvider.notifier).latestFor(server.id);
  final session = tab == null
      ? null
      : ref.read(sshConnectionServiceProvider).getSession(tab.id);
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SftpBrowserScreen(server: server, reuse: session),
    ),
  );
}
