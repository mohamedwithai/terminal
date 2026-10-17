import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/providers/session_tabs_providers.dart';
import 'package:ssh_app/screens/coming_soon_screen.dart';
import 'package:ssh_app/screens/hosts_screen.dart';
import 'package:ssh_app/screens/keys/keys_screen.dart';
import 'package:ssh_app/screens/snippets/snippets_screen.dart';
import 'package:ssh_app/screens/terminal_workspace.dart';

/// The bottom navigation (Hosts, Keys, Snippets, Files) and, over it, the
/// terminal workspace while sessions are shown. The workspace stays mounted
/// when it is hidden, so the sessions keep running behind the host list.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key, this.initialTab = 0});

  final int initialTab;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  late var _tab = widget.initialTab;

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(sessionTabsProvider);
    final showWorkspace = sessions.visible && sessions.tabs.isNotEmpty;
    return PopScope(
      // Back from the terminals goes to the host list; sessions stay open.
      canPop: !showWorkspace,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          ref.read(sessionTabsProvider.notifier).hide();
        }
      },
      child: Scaffold(
        body: IndexedStack(
          index: showWorkspace ? 4 : _tab,
          children: const [
            HostsScreen(),
            KeysScreen(),
            SnippetsScreen(),
            ComingSoonScreen(
              title: 'Files',
              icon: Icons.folder_outlined,
              message: 'Browse, upload and download files over SFTP.',
            ),
            TerminalWorkspace(),
          ],
        ),
        bottomNavigationBar: showWorkspace
            ? null
            : NavigationBar(
                selectedIndex: _tab,
                onDestinationSelected: (index) => setState(() => _tab = index),
                destinations: [
                  NavigationDestination(
                    icon: Badge(
                      isLabelVisible: sessions.count > 0,
                      label: Text('${sessions.count}'),
                      child: const Icon(Icons.dns_outlined),
                    ),
                    selectedIcon: const Icon(Icons.dns),
                    label: 'Hosts',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.key_outlined),
                    selectedIcon: Icon(Icons.key),
                    label: 'Keys',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.code),
                    label: 'Snippets',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.folder_outlined),
                    selectedIcon: Icon(Icons.folder),
                    label: 'Files',
                  ),
                ],
              ),
      ),
    );
  }
}
