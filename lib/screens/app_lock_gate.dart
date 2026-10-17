import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/providers/app_lock_providers.dart';
import 'package:ssh_app/providers/preferences_providers.dart';
import 'package:ssh_app/screens/lock_screen.dart';

/// Wraps the whole app. While locked, the lock screen covers it and nothing
/// underneath can be touched, focused or read by accessibility services.
/// It also feeds the app lifecycle to the lock and keeps the Android window
/// secure (hidden in recent apps, no screenshots) while the lock is on.
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate> {
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) =>
          ref.read(appLockProvider.notifier).onLifecycle(state),
    );
    ref
        .read(windowSecurityProvider)
        .setSecure(ref.read(appSettingsProvider).appLock);
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(appSettingsProvider.select((s) => s.appLock), (_, enabled) {
      ref.read(windowSecurityProvider).setSecure(enabled);
    });
    ref.listen(appLockProvider.select((s) => s.locked), (_, locked) {
      if (locked) FocusManager.instance.primaryFocus?.unfocus();
    });
    final locked = ref.watch(appLockProvider.select((s) => s.locked));
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeFocus(
          excluding: locked,
          child: IgnorePointer(
            ignoring: locked,
            child: ExcludeSemantics(excluding: locked, child: widget.child),
          ),
        ),
        if (locked) const Positioned.fill(child: LockScreen()),
      ],
    );
  }
}
