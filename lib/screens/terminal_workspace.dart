import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/providers/session_tabs_providers.dart';
import 'package:ssh_app/screens/terminal/session_tab_bar.dart';
import 'package:ssh_app/screens/terminal_screen.dart';

/// All open terminal sessions. Every tab's pane stays mounted, so each keeps
/// its own terminal buffer and connection while another tab is shown or the
/// host list is. Closing a tab removes its pane, which ends that session.
class TerminalWorkspace extends ConsumerWidget {
  const TerminalWorkspace({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sessionTabsProvider);
    if (state.tabs.isEmpty) return const SizedBox.shrink();
    final notifier = ref.read(sessionTabsProvider.notifier);
    // Not an IndexedStack: it wraps its children in unkeyed Visibility
    // widgets, so closing one tab would hand its place to the next pane and
    // destroy that pane's terminal. Each pane is keyed by its tab instead.
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final tab in state.tabs)
          Visibility(
            key: ValueKey('pane-${tab.id}'),
            visible: tab.id == state.activeId,
            maintainState: true,
            child: TerminalScreen(
              key: ValueKey(tab.id),
              server: tab.server,
              sessionId: tab.id,
              tabId: tab.id,
              active: state.visible && tab.id == state.activeId,
              tabsBar: const SessionTabBar(),
              onBack: notifier.hide,
              onClose: () => notifier.close(tab.id),
            ),
          ),
      ],
    );
  }
}
