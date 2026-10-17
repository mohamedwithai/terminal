import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/app_settings.dart';
import 'package:ssh_app/providers/app_lock_providers.dart';
import 'package:ssh_app/providers/preferences_providers.dart';
import 'package:ssh_app/services/app_lock/pin_store.dart';
import 'package:ssh_app/theme/tokens.dart';

/// The app lock section of Settings.
class AppLockSettings extends ConsumerWidget {
  const AppLockSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final notifier = ref.read(appSettingsProvider.notifier);
    final biometrics = ref.watch(_biometricsAvailable).asData?.value ?? false;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          SwitchListTile(
            key: const ValueKey('app-lock-switch'),
            title: const Text('App lock'),
            subtitle: const Text(
              'Ask for a PIN to open the app. Also hides it in recent apps '
              'and blocks screenshots.',
            ),
            value: settings.appLock,
            onChanged: (on) =>
                on ? _enable(context, ref) : unawaited(_disable(context, ref)),
          ),
          if (settings.appLock) ...[
            const Divider(),
            SwitchListTile(
              key: const ValueKey('app-lock-biometrics'),
              title: const Text('Fingerprint or face'),
              subtitle: Text(
                biometrics
                    ? 'Unlock without typing the PIN'
                    : 'Not set up on this device',
              ),
              value: settings.lockBiometrics && biometrics,
              onChanged: biometrics
                  ? (on) => unawaited(_setBiometrics(context, ref, on))
                  : null,
            ),
            const Divider(),
            ListTile(
              key: const ValueKey('app-lock-timeout'),
              title: const Text('Lock'),
              subtitle: Text(settings.lockTimeout.label),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final choice = await showDialog<LockTimeout>(
                  context: context,
                  builder: (dialogContext) => SimpleDialog(
                    title: const Text('Lock the app'),
                    children: [
                      RadioGroup<LockTimeout>(
                        groupValue: settings.lockTimeout,
                        onChanged: (value) =>
                            Navigator.of(dialogContext).pop(value),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final timeout in LockTimeout.values)
                              RadioListTile<LockTimeout>(
                                key: ValueKey('timeout-${timeout.name}'),
                                title: Text(timeout.label),
                                value: timeout,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
                if (choice != null) {
                  await notifier.update((s) => s.copyWith(lockTimeout: choice));
                }
              },
            ),
            const Divider(),
            ListTile(
              key: const ValueKey('app-lock-change-pin'),
              title: const Text('Change PIN'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => unawaited(_changePin(context, ref)),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _enable(BuildContext context, WidgetRef ref) async {
    final pin = await showDialog<String>(
      context: context,
      builder: (_) => const PinSetupDialog(title: 'Choose a PIN'),
    );
    if (pin == null || !context.mounted) return;
    try {
      await ref.read(pinStoreProvider).setPin(pin);
    } catch (error) {
      if (context.mounted) _message(context, 'Could not save the PIN. $error');
      return;
    }
    await ref
        .read(appSettingsProvider.notifier)
        .update((s) => s.copyWith(appLock: true));
    final available = await ref
        .read(biometricAuthenticatorProvider)
        .isAvailable();
    if (!available || !context.mounted) return;
    final use = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Use fingerprint or face?'),
        content: const Text(
          'You can unlock with it instead of typing the PIN. The PIN still '
          'works.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Use it'),
          ),
        ],
      ),
    );
    if (use == true && context.mounted) {
      await _setBiometrics(context, ref, true);
    }
  }

  Future<void> _disable(BuildContext context, WidgetRef ref) async {
    if (!await confirmPin(context, ref, title: 'Turn off app lock')) return;
    await ref.read(pinStoreProvider).clear();
    await ref
        .read(appSettingsProvider.notifier)
        .update((s) => s.copyWith(appLock: false, lockBiometrics: false));
  }

  Future<void> _changePin(BuildContext context, WidgetRef ref) async {
    final confirmed = await confirmPin(
      context,
      ref,
      title: 'Enter your current PIN',
    );
    if (!confirmed) return;
    if (!context.mounted) return;
    final pin = await showDialog<String>(
      context: context,
      builder: (_) => const PinSetupDialog(title: 'Choose a new PIN'),
    );
    if (pin == null || !context.mounted) return;
    try {
      await ref.read(pinStoreProvider).setPin(pin);
      if (context.mounted) _message(context, 'PIN changed.');
    } catch (error) {
      if (context.mounted) _message(context, 'Could not save the PIN. $error');
    }
  }

  Future<void> _setBiometrics(
    BuildContext context,
    WidgetRef ref,
    bool on,
  ) async {
    final notifier = ref.read(appSettingsProvider.notifier);
    if (!on) {
      await notifier.update((s) => s.copyWith(lockBiometrics: false));
      return;
    }
    // Prove it works before relying on it, so the user is not locked out.
    final ok = await ref
        .read(appLockProvider.notifier)
        .runExternal(
          () => ref
              .read(biometricAuthenticatorProvider)
              .authenticate('Confirm fingerprint or face for SSH'),
        );
    if (ok) {
      await notifier.update((s) => s.copyWith(lockBiometrics: true));
    } else if (context.mounted) {
      _message(context, 'Fingerprint or face was not confirmed.');
    }
  }

  static void _message(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }
}

final _biometricsAvailable = FutureProvider<bool>((ref) {
  return ref.watch(biometricAuthenticatorProvider).isAvailable();
});

/// Asks for the current PIN. True if it was right.
Future<bool> confirmPin(
  BuildContext context,
  WidgetRef ref, {
  required String title,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) =>
        PinConfirmDialog(title: title, store: ref.read(pinStoreProvider)),
  );
  return ok == true;
}

/// Enter a new PIN twice.
class PinSetupDialog extends StatefulWidget {
  const PinSetupDialog({super.key, required this.title});

  final String title;

  @override
  State<PinSetupDialog> createState() => _PinSetupDialogState();
}

class _PinSetupDialogState extends State<PinSetupDialog> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    final problem = pinProblem(_pin.text);
    if (problem != null) {
      setState(() => _error = problem);
    } else if (_pin.text != _confirm.text) {
      setState(() => _error = 'The two PINs do not match.');
    } else {
      Navigator.of(context).pop(_pin.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('pin-new'),
            controller: _pin,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 12,
            decoration: const InputDecoration(
              labelText: 'PIN',
              helperText: '4 to 12 digits',
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('pin-confirm'),
            controller: _confirm,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 12,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Repeat PIN',
              errorText: _error,
              counterText: '',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

/// Enter the current PIN; closes with true when it is right.
class PinConfirmDialog extends StatefulWidget {
  const PinConfirmDialog({super.key, required this.title, required this.store});

  final String title;
  final PinStore store;

  @override
  State<PinConfirmDialog> createState() => _PinConfirmDialogState();
}

class _PinConfirmDialogState extends State<PinConfirmDialog> {
  final _pin = TextEditingController();
  String? _error;
  var _checking = false;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_checking || _pin.text.isEmpty) return;
    setState(() => _checking = true);
    final result = await widget.store.verify(_pin.text);
    if (!mounted) return;
    switch (result) {
      case PinCorrect():
        Navigator.of(context).pop(true);
      case PinWrong(:final lockedFor):
        setState(() {
          _checking = false;
          _pin.clear();
          _error = lockedFor == null
              ? 'Wrong PIN'
              : 'Too many tries. Wait ${lockedFor.inSeconds} s.';
        });
      case PinLockedOut(:final remaining):
        setState(() {
          _checking = false;
          _pin.clear();
          _error = 'Too many tries. Wait ${remaining.inSeconds + 1} s.';
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const ValueKey('pin-current'),
        controller: _pin,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        maxLength: 12,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: 'PIN',
          errorText: _error,
          counterText: '',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _checking ? null : _submit,
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}

/// A short note under Security about what the lock does and does not do.
class AppLockNote extends StatelessWidget {
  const AppLockNote({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Text(
        'The lock covers the app on this device. Open SSH sessions stay '
        'connected while it is locked. If you forget the PIN, clear the '
        'app\'s data.',
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: AppColors.muted),
      ),
    );
  }
}
