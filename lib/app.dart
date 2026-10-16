import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/providers/session_keeper_providers.dart';
import 'package:ssh_app/screens/server_list_screen.dart';
import 'package:ssh_app/theme/app_theme.dart';

class SshApp extends StatelessWidget {
  const SshApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SSH',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: const ServerListScreen(),
    );
  }
}

/// Starts [sessionKeeperProvider] for the life of the app, which keeps
/// sessions connected while the user is in another app. The web build has
/// no SSH sessions to keep.
class SessionKeeperScope extends ConsumerWidget {
  const SessionKeeperScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!kIsWeb) {
      ref.watch(sessionKeeperProvider);
    }
    return child;
  }
}
