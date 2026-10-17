import 'package:flutter/material.dart';
import 'package:ssh_app/screens/coming_soon_screen.dart';
import 'package:ssh_app/screens/hosts_screen.dart';
import 'package:ssh_app/screens/keys/keys_screen.dart';
import 'package:ssh_app/screens/snippets/snippets_screen.dart';

/// The bottom navigation: Hosts, Keys, Snippets and Files.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.initialTab = 0});

  final int initialTab;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late var _tab = widget.initialTab;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: const [
          HostsScreen(),
          KeysScreen(),
          SnippetsScreen(),
          ComingSoonScreen(
            title: 'Files',
            icon: Icons.folder_outlined,
            message: 'Browse, upload and download files over SFTP.',
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dns_outlined),
            selectedIcon: Icon(Icons.dns),
            label: 'Hosts',
          ),
          NavigationDestination(
            icon: Icon(Icons.key_outlined),
            selectedIcon: Icon(Icons.key),
            label: 'Keys',
          ),
          NavigationDestination(icon: Icon(Icons.code), label: 'Snippets'),
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: 'Files',
          ),
        ],
      ),
    );
  }
}
