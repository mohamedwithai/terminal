import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/providers/session_keeper_providers.dart';
import 'package:ssh_app/screens/app_lock_gate.dart';
import 'package:ssh_app/screens/home_screen.dart';
import 'package:ssh_app/services/session_keeper.dart';
import 'package:ssh_app/theme/app_theme.dart';

/// Shows app-wide messages on whatever screen is open.
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

class SshApp extends StatelessWidget {
  const SshApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SSH',
      theme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      builder: (context, child) =>
          AppLockGate(child: child ?? const SizedBox()),
      home: const HomeScreen(),
    );
  }
}

/// Starts [sessionKeeperProvider] for the life of the app, which keeps
/// sessions connected while the user is in another app, and shows its
/// notifications-off hint. The web build has no SSH sessions to keep.
class SessionKeeperScope extends ConsumerStatefulWidget {
  const SessionKeeperScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SessionKeeperScope> createState() => _SessionKeeperScopeState();
}

class _SessionKeeperScopeState extends ConsumerState<SessionKeeperScope> {
  SessionKeeper? _keeper;
  StreamSubscription<void>? _hints;

  @override
  void dispose() {
    _hints?.cancel();
    super.dispose();
  }

  void _showNotificationHint() {
    final foregroundService = ref.read(sessionForegroundServiceProvider);
    rootScaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: const Text(
          'Notifications are off. Your session may disconnect when you '
          'switch apps.',
        ),
        duration: const Duration(seconds: 10),
        persist: false,
        showCloseIcon: true,
        action: SnackBarAction(
          label: 'Open settings',
          onPressed: () =>
              unawaited(foregroundService.openNotificationSettings()),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) {
      final keeper = ref.watch(sessionKeeperProvider);
      if (!identical(keeper, _keeper)) {
        _keeper = keeper;
        _hints?.cancel();
        _hints = keeper.notificationHints.listen(
          (_) => _showNotificationHint(),
        );
      }
    }
    return widget.child;
  }
}
