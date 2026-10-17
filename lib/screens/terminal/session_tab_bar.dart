import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/providers/session_tabs_providers.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/screens/widgets/host_avatar.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';
import 'package:ssh_app/theme/tokens.dart';

/// The color of a tab's status dot.
Color tabStatusColor(TabStatus status) => switch (status) {
  TabStatus.connected => AppColors.accent,
  TabStatus.busy => AppColors.warn,
  TabStatus.problem => AppColors.error,
  TabStatus.idle => AppColors.muted,
};

/// How a connection state shows on its tab.
TabStatus tabStatusFor(SSHConnectionState? state, {required bool attempted}) {
  return switch (state?.status) {
    SSHConnectionStatus.connected => TabStatus.connected,
    SSHConnectionStatus.connecting ||
    SSHConnectionStatus.awaitingHostKeyConfirmation ||
    SSHConnectionStatus.reconnecting => TabStatus.busy,
    SSHConnectionStatus.error ||
    SSHConnectionStatus.disconnected => TabStatus.problem,
    null => attempted ? TabStatus.busy : TabStatus.idle,
  };
}

/// Names for the tabs: the host's label, numbered when the same host is
/// open more than once ("Build box", "Build box 2").
List<String> tabLabels(List<SessionTab> tabs) {
  final seen = <String, int>{};
  final totals = <String, int>{};
  for (final tab in tabs) {
    totals.update(tab.server.id, (n) => n + 1, ifAbsent: () => 1);
  }
  return [
    for (final tab in tabs)
      () {
        final n = seen.update(tab.server.id, (n) => n + 1, ifAbsent: () => 1);
        return totals[tab.server.id] == 1
            ? tab.server.label
            : '${tab.server.label} $n';
      }(),
  ];
}

/// Closes [tab]'s session after asking, if it is connected. Only that
/// session ends. Returns whether it was closed.
Future<bool> closeSessionTab(
  BuildContext context,
  WidgetRef ref,
  SessionTab tab, {
  String? label,
}) async {
  if (tab.status == TabStatus.connected || tab.status == TabStatus.busy) {
    final close = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Close this session?'),
        content: Text(
          'Disconnect from ${label ?? tab.server.label}? Your other sessions '
          'stay open.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Stay'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Close session'),
          ),
        ],
      ),
    );
    if (close != true) return false;
  }
  ref.read(sessionTabsProvider.notifier).close(tab.id);
  return true;
}

/// Picks a host for a new session. The same host can be picked again.
Future<ServerConfig?> pickHostForSession(
  BuildContext context,
  List<ServerConfig> hosts,
) {
  return showModalBottomSheet<ServerConfig>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'New session',
              style: Theme.of(sheetContext).textTheme.titleLarge,
            ),
          ),
          if (hosts.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('Add a host first.'),
            ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final host in hosts)
                  ListTile(
                    key: ValueKey('new-session-${host.id}'),
                    leading: HostAvatar(server: host),
                    title: Text(host.label),
                    subtitle: Text('${host.username}@${host.host}'),
                    onTap: () => Navigator.of(sheetContext).pop(host),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// The row of session tabs under the terminal bar.
class SessionTabBar extends ConsumerWidget {
  const SessionTabBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sessionTabsProvider);
    final labels = tabLabels(state.tabs);
    return Container(
      height: 44,
      decoration: const BoxDecoration(
        color: AppColors.bar,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(8, 4, 4, 6),
              children: [
                for (final (i, tab) in state.tabs.indexed)
                  _TabChip(
                    key: ValueKey('tab-${tab.id}'),
                    label: labels[i],
                    status: tab.status,
                    selected: tab.id == state.activeId,
                    onTap: () =>
                        ref.read(sessionTabsProvider.notifier).focus(tab.id),
                    onClose: () => unawaited(
                      closeSessionTab(context, ref, tab, label: labels[i]),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('new-session'),
            tooltip: 'New session',
            icon: const Icon(Icons.add),
            onPressed: () async {
              final hosts = await ref.read(serverListProvider.future);
              if (!context.mounted) return;
              final host = await pickHostForSession(context, hosts);
              if (host != null) {
                ref.read(sessionTabsProvider.notifier).open(host);
              }
            },
          ),
        ],
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    super.key,
    required this.label,
    required this.status,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  final String label;
  final TabStatus status;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: selected ? AppColors.accentSoft : AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.key),
          side: BorderSide(
            color: selected ? AppColors.accent : AppColors.border,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                StatusDot(color: tabStatusColor(status)),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: selected ? AppColors.text : AppColors.muted,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                InkResponse(
                  onTap: onClose,
                  radius: 18,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      Icons.close,
                      size: 16,
                      color: AppColors.muted,
                      semanticLabel: 'Close $label',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
