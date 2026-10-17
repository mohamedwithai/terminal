import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/providers/app_lock_providers.dart';
import 'package:ssh_app/providers/preferences_providers.dart';
import 'package:ssh_app/services/app_lock/pin_store.dart';
import 'package:ssh_app/theme/tokens.dart';

/// Covers the app until the PIN is entered or fingerprint or face accepts.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  var _entered = '';
  int? _length;
  String? _message;
  var _checking = false;
  DateTime? _waitUntil;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final store = ref.read(pinStoreProvider);
    final length = await store.length();
    final wait = await store.lockoutRemaining();
    if (!mounted) return;
    setState(() {
      _length = length;
      if (wait != null) _startWait(wait);
    });
    if (ref.read(appSettingsProvider).lockBiometrics && wait == null) {
      unawaited(_biometrics());
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _startWait(Duration wait) {
    _waitUntil = DateTime.now().add(wait);
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_remaining == null) {
        _tick?.cancel();
        setState(() {
          _waitUntil = null;
          _message = null;
        });
      } else {
        setState(() {});
      }
    });
  }

  Duration? get _remaining {
    final until = _waitUntil;
    if (until == null) return null;
    final left = until.difference(DateTime.now());
    return left > Duration.zero ? left : null;
  }

  Future<void> _biometrics() async {
    final ok = await ref.read(appLockProvider.notifier).unlockWithBiometrics();
    if (!ok && mounted) {
      setState(() => _message = null);
    }
  }

  void _press(String digit) {
    if (_checking || _remaining != null) return;
    if (_entered.length >= 12) return;
    HapticFeedback.selectionClick();
    setState(() {
      _entered += digit;
      _message = null;
    });
    if (_length != null && _entered.length == _length) {
      unawaited(_submit());
    }
  }

  void _back() {
    if (_checking || _entered.isEmpty) return;
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  Future<void> _submit() async {
    if (_entered.isEmpty || _checking) return;
    setState(() => _checking = true);
    final result = await ref
        .read(appLockProvider.notifier)
        .unlockWithPin(_entered);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _entered = '';
      switch (result) {
        case PinCorrect():
          break;
        case PinWrong(:final lockedFor, :final failures):
          _message = lockedFor == null
              ? 'Wrong PIN'
              : 'Wrong PIN ($failures tries)';
          if (lockedFor != null) _startWait(lockedFor);
        case PinLockedOut(:final remaining):
          _startWait(remaining);
      }
    });
  }

  String _wait(Duration d) {
    if (d.inMinutes >= 1) {
      return '${d.inMinutes} min ${d.inSeconds % 60} s';
    }
    return '${d.inSeconds + 1} s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = _remaining;
    final biometrics = ref.watch(
      appSettingsProvider.select((s) => s.lockBiometrics),
    );
    final dots = _length ?? (_entered.length < 4 ? 4 : _entered.length);
    return Material(
      key: const ValueKey('lock-screen'),
      color: AppColors.background,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(24),
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
                      Icons.lock_outline,
                      color: AppColors.accent,
                      size: 30,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('SSH is locked', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    'Enter your PIN',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppColors.muted,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < dots; i++)
                        Container(
                          width: 14,
                          height: 14,
                          margin: const EdgeInsets.symmetric(horizontal: 6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: i < _entered.length
                                ? AppColors.accent
                                : Colors.transparent,
                            border: Border.all(
                              color: i < _entered.length
                                  ? AppColors.accent
                                  : AppColors.borderStrong,
                              width: 1.5,
                            ),
                          ),
                        ),
                    ],
                  ),
                  SizedBox(
                    height: 44,
                    child: Center(
                      child: Text(
                        remaining != null
                            ? 'Too many tries. Wait ${_wait(remaining)}.'
                            : (_message ?? ''),
                        key: const ValueKey('lock-message'),
                        style: const TextStyle(color: AppColors.error),
                      ),
                    ),
                  ),
                  for (final row in const [
                    ['1', '2', '3'],
                    ['4', '5', '6'],
                    ['7', '8', '9'],
                  ])
                    _PadRow(
                      children: [
                        for (final digit in row)
                          _PadKey(
                            key: ValueKey('pin-$digit'),
                            label: digit,
                            onPressed: () => _press(digit),
                          ),
                      ],
                    ),
                  _PadRow(
                    children: [
                      biometrics
                          ? _PadKey(
                              key: const ValueKey('pin-biometric'),
                              icon: Icons.fingerprint,
                              tooltip: 'Use fingerprint or face',
                              onPressed: _biometrics,
                            )
                          : const SizedBox(width: 72, height: 72),
                      _PadKey(
                        key: const ValueKey('pin-0'),
                        label: '0',
                        onPressed: () => _press('0'),
                      ),
                      _PadKey(
                        key: const ValueKey('pin-back'),
                        icon: Icons.backspace_outlined,
                        tooltip: 'Delete',
                        onPressed: _back,
                      ),
                    ],
                  ),
                  if (_length == null) ...[
                    const SizedBox(height: 12),
                    FilledButton(
                      key: const ValueKey('pin-ok'),
                      onPressed: _entered.isEmpty ? null : _submit,
                      child: const Text('Unlock'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PadRow extends StatelessWidget {
  const _PadRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: children,
      ),
    );
  }
}

class _PadKey extends StatelessWidget {
  const _PadKey({
    super.key,
    this.label,
    this.icon,
    this.tooltip,
    required this.onPressed,
  });

  final String? label;
  final IconData? icon;
  final String? tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final key = SizedBox(
      width: 72,
      height: 72,
      child: Material(
        color: AppColors.surface,
        shape: const CircleBorder(side: BorderSide(color: AppColors.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Center(
            child: label != null
                ? Text(
                    label!,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w500,
                      color: AppColors.text,
                    ),
                  )
                : Icon(icon, color: AppColors.text),
          ),
        ),
      ),
    );
    // No Tooltip: the lock screen is above the Navigator, so there is no
    // Overlay for it. A label serves screen readers.
    return Semantics(
      button: true,
      label: tooltip ?? label,
      excludeSemantics: true,
      onTap: onPressed,
      child: key,
    );
  }
}
