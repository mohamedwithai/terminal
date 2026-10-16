import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';
import 'package:ssh_app/theme/tokens.dart';

/// `SHA256:Q0ynKtbg...` as `Q0yn Ktbg ...`, easier to compare by eye.
String groupFingerprint(String fingerprint, {int size = 4}) {
  final colon = fingerprint.indexOf(':');
  final body = colon < 0 ? fingerprint : fingerprint.substring(colon + 1);
  final groups = <String>[];
  for (var i = 0; i < body.length; i += size) {
    groups.add(body.substring(i, i + size > body.length ? body.length : i + size));
  }
  return groups.join(' ');
}

/// The algorithm before the colon, such as `SHA256`.
String fingerprintAlgorithm(String fingerprint) {
  final colon = fingerprint.indexOf(':');
  return colon < 0 ? 'SHA256' : fingerprint.substring(0, colon);
}

/// A readable name for an SSH host key algorithm.
String hostKeyTypeLabel(String keyType) {
  if (keyType == 'ssh-ed25519') return 'ED25519';
  if (keyType.startsWith('ecdsa-')) return 'ECDSA';
  if (keyType == 'ssh-rsa' || keyType.startsWith('rsa-')) return 'RSA';
  return keyType;
}

/// What to run on the server to print the fingerprint of its [keyType] key.
String hostKeyCheckCommand(String keyType) {
  final file = switch (hostKeyTypeLabel(keyType)) {
    'ED25519' => 'ed25519',
    'ECDSA' => 'ecdsa',
    'RSA' => 'rsa',
    _ => null,
  };
  if (file == null) {
    return r'for f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$f"; done';
  }
  return 'ssh-keygen -lf /etc/ssh/ssh_host_${file}_key.pub';
}

/// Asks whether to trust an unknown host key. Resolves [challenge]: Trust
/// accepts it, anything else (Cancel, Back, closing) rejects it. Closes by
/// itself if the attempt ends while it is open.
Future<void> showHostKeySheet(
  BuildContext context,
  HostKeyChallenge challenge,
) async {
  final trusted = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    enableDrag: false,
    useSafeArea: true,
    builder: (_) => HostKeySheet(challenge: challenge),
  );
  if (trusted == true) {
    challenge.accept();
  } else {
    challenge.reject();
  }
}

class HostKeySheet extends StatefulWidget {
  const HostKeySheet({super.key, required this.challenge});

  final HostKeyChallenge challenge;

  @override
  State<HostKeySheet> createState() => _HostKeySheetState();
}

class _HostKeySheetState extends State<HostKeySheet> {
  var _closed = false;

  @override
  void initState() {
    super.initState();
    widget.challenge.decision.then((_) => _close(null));
  }

  void _close(bool? trusted) {
    if (_closed || !mounted) {
      return;
    }
    _closed = true;
    Navigator.of(context).pop(trusted);
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('$what copied')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final challenge = widget.challenge;
    final command = hostKeyCheckCommand(challenge.keyType);
    const mono = TextStyle(fontFamily: AppFonts.mono, color: AppColors.text);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: AppSizes.minTouch,
                height: AppSizes.minTouch,
                decoration: BoxDecoration(
                  color: AppColors.warnSoft,
                  borderRadius: BorderRadius.circular(AppRadii.button),
                ),
                child: const Icon(Icons.shield_outlined, color: AppColors.warn),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text('Trust this host?', style: theme.textTheme.titleLarge),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'First connection to ${challenge.host}:${challenge.port}. Check '
            'that this fingerprint belongs to the server before you trust it.',
            style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.muted),
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            decoration: BoxDecoration(
              color: AppColors.terminalBackground,
              borderRadius: BorderRadius.circular(AppRadii.button),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${hostKeyTypeLabel(challenge.keyType)} · '
                        '${fingerprintAlgorithm(challenge.fingerprint)}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: AppColors.muted,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        groupFingerprint(challenge.fingerprint),
                        key: const ValueKey('host-key-fingerprint'),
                        style: mono.copyWith(fontSize: 16, height: 1.5),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Copy fingerprint',
                  icon: const Icon(Icons.copy, size: 20),
                  onPressed: () => _copy(challenge.fingerprint, 'Fingerprint'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              iconColor: AppColors.accent,
              collapsedIconColor: AppColors.muted,
              title: const Text(
                'How do I check?',
                style: TextStyle(color: AppColors.accent),
              ),
              children: [
                const Text(
                  'On the server, or ask its admin to run:',
                  style: TextStyle(color: AppColors.muted),
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                  decoration: BoxDecoration(
                    color: AppColors.terminalBackground,
                    borderRadius: BorderRadius.circular(AppRadii.key),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          command,
                          style: mono.copyWith(fontSize: 13),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copy command',
                        icon: const Icon(Icons.copy, size: 18),
                        onPressed: () => _copy(command, 'Command'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'It prints the same SHA256 fingerprint. Every group must '
                  'match; if one differs, do not connect.',
                  style: TextStyle(color: AppColors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _close(false),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => _close(true),
                  child: const Text('Trust & connect'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
