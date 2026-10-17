import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/providers/preferences_providers.dart';
import 'package:ssh_app/providers/snippet_providers.dart';
import 'package:ssh_app/providers/ssh_providers.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/screens/format.dart';
import 'package:ssh_app/screens/server_form_screen.dart';
import 'package:ssh_app/screens/settings_screen.dart';
import 'package:ssh_app/screens/terminal_screen.dart';
import 'package:ssh_app/screens/widgets/host_avatar.dart';
import 'package:ssh_app/theme/tokens.dart';

/// Saved hosts: search, tag filters, the sessions open right now, and the
/// full list. Credentials stay in the vault and are never shown.
class HostsScreen extends ConsumerStatefulWidget {
  const HostsScreen({super.key});

  @override
  ConsumerState<HostsScreen> createState() => _HostsScreenState();
}

class _HostsScreenState extends ConsumerState<HostsScreen> {
  final _search = TextEditingController();
  String? _tag;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _openForm([ServerConfig? server]) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ServerFormScreen(server: server)),
    );
  }

  void _connect(ServerConfig server) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => TerminalScreen(server: server)),
    );
  }

  Future<void> _addTag() async {
    final tag = await showDialog<String>(
      context: context,
      builder: (_) => const _NewTagDialog(),
    );
    if (tag != null && tag.trim().isNotEmpty) {
      await ref.read(appSettingsProvider.notifier).addTag(tag);
      setState(() => _tag = tag.trim());
    }
  }

  bool _matches(ServerConfig server, String query) {
    if (_tag != null && !server.tags.contains(_tag)) {
      return false;
    }
    if (query.isEmpty) {
      return true;
    }
    return [
      server.label,
      server.host,
      server.username,
      ...server.tags,
    ].any((field) => field.toLowerCase().contains(query));
  }

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(serverListProvider);
    final secureStorageAvailable = ref.watch(secureStorageAvailableProvider);
    final settings = ref.watch(appSettingsProvider);
    final active = ref.watch(activeSessionsProvider).asData?.value ?? const [];
    final now = ref.watch(clockProvider)();

    final tabsByServer = <String, int>{};
    for (final session in active) {
      tabsByServer.update(session.server.id, (n) => n + 1, ifAbsent: () => 1);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hosts'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.tune),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'hosts-fab',
        onPressed: _openForm,
        icon: const Icon(Icons.add),
        label: const Text('New host'),
      ),
      body: Column(
        children: [
          if (!secureStorageAvailable) const _InsecureContextBanner(),
          Expanded(
            child: servers.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => _LoadError(
                message: error.toString(),
                onRetry: () => ref.invalidate(serverListProvider),
              ),
              data: (items) {
                if (items.isEmpty) {
                  return _EmptyState(onAdd: _openForm);
                }
                final query = _search.text.trim().toLowerCase();
                final tags = {
                  ...settings.tags,
                  for (final server in items) ...server.tags,
                }.toList();
                final shown = [
                  for (final server in items)
                    if (_matches(server, query)) server,
                ];
                final activeShown = [
                  for (final server in shown)
                    if (tabsByServer.containsKey(server.id)) server,
                ];
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 104),
                  children: [
                    _SearchField(
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 12),
                    _TagChips(
                      tags: tags,
                      selected: _tag,
                      onSelected: (tag) => setState(() => _tag = tag),
                      onAdd: _addTag,
                    ),
                    if (activeShown.isNotEmpty) ...[
                      const _SectionHeader(
                        title: 'Active now',
                        dotColor: AppColors.accent,
                      ),
                      for (final server in activeShown)
                        _HostRow(
                          server: server,
                          now: now,
                          tabs: tabsByServer[server.id],
                          onTap: () => _connect(server),
                          onEdit: () => _openForm(server),
                        ),
                    ],
                    _SectionHeader(
                      title: _tag ?? 'All hosts',
                      count: shown.length,
                    ),
                    if (shown.isEmpty)
                      const _NoMatches()
                    else
                      for (final server in shown)
                        _HostRow(
                          server: server,
                          now: now,
                          onTap: () => _connect(server),
                          onEdit: () => _openForm(server),
                        ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: 'Search hosts',
        prefixIcon: const Icon(Icons.search, color: AppColors.muted),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                icon: const Icon(Icons.close, color: AppColors.muted),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
      ),
    );
  }
}

class _TagChips extends StatelessWidget {
  const _TagChips({
    required this.tags,
    required this.selected,
    required this.onSelected,
    required this.onAdd,
  });

  final List<String> tags;
  final String? selected;
  final ValueChanged<String?> onSelected;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: AppSizes.minTouch,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _chip('All', selected == null, () => onSelected(null)),
          for (final tag in tags)
            _chip(tag, selected == tag, () => onSelected(tag)),
          ActionChip(
            tooltip: 'New tag',
            avatar: const Icon(Icons.add, size: 18, color: AppColors.accent),
            label: const Text('Tag'),
            onPressed: onAdd,
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, bool isSelected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: isSelected,
        showCheckmark: false,
        onSelected: (_) => onTap(),
        labelStyle: TextStyle(
          color: isSelected ? AppColors.accent : AppColors.text,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.count, this.dotColor});

  final String title;
  final int? count;
  final Color? dotColor;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelLarge?.copyWith(
      color: AppColors.muted,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.4,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 10),
      child: Row(
        children: [
          if (dotColor != null) ...[
            StatusDot(color: dotColor!),
            const SizedBox(width: 8),
          ],
          Text(title.toUpperCase(), style: style),
          if (count != null) ...[
            const SizedBox(width: 8),
            Text('$count', style: style),
          ],
        ],
      ),
    );
  }
}

class _HostRow extends ConsumerWidget {
  const _HostRow({
    required this.server,
    required this.now,
    required this.onTap,
    required this.onEdit,
    this.tabs,
  });

  final ServerConfig server;
  final DateTime now;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  /// Open sessions to this host, in the "Active now" section.
  final int? tabs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final address = server.port == 22
        ? '${server.username}@${server.host}'
        : '${server.username}@${server.host}:${server.port}';
    final connected = server.lastConnectedAt;
    final auth = switch (server.authType) {
      AuthType.password => 'Password',
      AuthType.privateKey => 'Key',
    };
    final tabs = this.tabs;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
            child: Row(
              children: [
                HostAvatar(
                  server: server,
                  dotColor: tabs == null ? null : AppColors.accent,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        server.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        address,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: AppColors.muted,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            server.authType == AuthType.privateKey
                                ? Icons.key_outlined
                                : Icons.password,
                            size: 14,
                            color: AppColors.muted,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              connected == null
                                  ? '$auth · Never connected'
                                  : '$auth · Last connected '
                                        '${formatRelativeTime(connected, now)}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (tabs != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.accentSoft,
                      borderRadius: BorderRadius.circular(AppRadii.key),
                    ),
                    child: Text(
                      tabs == 1 ? '1 tab' : '$tabs tabs',
                      style: const TextStyle(
                        color: AppColors.accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                _HostMenu(server: server, onEdit: onEdit),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HostMenu extends ConsumerWidget {
  const _HostMenu({required this.server, required this.onEdit});

  final ServerConfig server;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, color: AppColors.muted),
      tooltip: 'Host options',
      onSelected: (value) async {
        if (value == 'edit') {
          onEdit();
        } else if (value == 'delete') {
          final confirmed = await _confirmDelete(context, server.label);
          if (confirmed && context.mounted) {
            await ref.read(serverListProvider.notifier).delete(server.id);
            await ref.read(snippetListProvider.notifier).forgetHost(server.id);
          }
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: 'edit',
          child: ListTile(
            leading: Icon(Icons.edit_outlined),
            title: Text('Edit'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: ListTile(
            leading: Icon(Icons.delete_outline, color: AppColors.error),
            title: Text('Delete', style: TextStyle(color: AppColors.error)),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }
}

class _NewTagDialog extends StatefulWidget {
  const _NewTagDialog();

  @override
  State<_NewTagDialog> createState() => _NewTagDialogState();
}

class _NewTagDialogState extends State<_NewTagDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New tag'),
      content: TextField(
        controller: _name,
        autofocus: true,
        maxLength: 24,
        decoration: const InputDecoration(hintText: 'For example: Work'),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_name.text),
          child: const Text('Add'),
        ),
      ],
    );
  }
}

class _NoMatches extends StatelessWidget {
  const _NoMatches();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Text(
        'No hosts match.',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(color: AppColors.muted),
      ),
    );
  }
}

/// Shown on the web over plain HTTP, where the browser hides the WebCrypto
/// API that secure storage encrypts with.
class _InsecureContextBanner extends StatelessWidget {
  const _InsecureContextBanner();

  @override
  Widget build(BuildContext context) {
    return const Material(
      color: AppColors.errorSoft,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.no_encryption_outlined, color: AppColors.error),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Secure storage needs HTTPS. Saving is disabled.',
                style: TextStyle(color: AppColors.error),
              ),
            ),
          ],
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
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadii.card),
                border: Border.all(color: AppColors.border),
              ),
              child: const Icon(
                Icons.dns_outlined,
                color: AppColors.accent,
                size: 30,
              ),
            ),
            const SizedBox(height: 16),
            Text('No hosts yet', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Add a host to keep its address here and its password or key '
              'in encrypted storage.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('New host'),
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
            const Icon(Icons.error_outline, color: AppColors.error),
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
        title: const Text('Delete host?'),
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
