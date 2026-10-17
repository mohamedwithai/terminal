import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/ssh_key_record.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/screens/widgets/text_prompt_dialog.dart';
import 'package:ssh_app/services/vault_exception.dart';
import 'package:ssh_app/theme/tokens.dart';

/// One saved key: its public key to copy or share, its fingerprint, and
/// which hosts use it.
class KeyDetailScreen extends ConsumerWidget {
  const KeyDetailScreen({
    super.key,
    required this.keyId,
    this.justCreated = false,
  });

  final String keyId;

  /// Shown right after generating or importing, with the next step.
  final bool justCreated;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keys = ref.watch(keyListProvider);
    final record = keys.asData?.value
        .where((key) => key.id == keyId)
        .firstOrNull;
    if (record == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: keys.isLoading
              ? const CircularProgressIndicator()
              : const Text('This key no longer exists.'),
        ),
      );
    }
    final users = [
      for (final server
          in ref.watch(serverListProvider).asData?.value ?? const [])
        if (server.keyId == keyId) server,
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(record.name),
        actions: [
          IconButton(
            tooltip: 'Rename',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _rename(context, ref, record),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (justCreated)
            _Banner(
              text:
                  'Key saved. Add the public key below to '
                  '~/.ssh/authorized_keys on each server, then pick this key '
                  'in the host settings.',
            ),
          _Section('Details'),
          Card(
            child: Column(
              children: [
                _Row('Type', record.type),
                const Divider(),
                _Row('Passphrase', record.encrypted ? 'Protected' : 'None'),
                const Divider(),
                _Row('Created', _date(record.createdAt)),
              ],
            ),
          ),
          _Section('Public key'),
          _CopyBlock(
            key: const ValueKey('public-key'),
            text: record.publicKey,
            copyLabel: 'Public key',
            onShare: () => _share(context, ref, record),
          ),
          _Section('Fingerprint'),
          _CopyBlock(
            key: const ValueKey('fingerprint'),
            text: record.fingerprint,
            copyLabel: 'Fingerprint',
          ),
          _Section('Used by'),
          if (users.isEmpty)
            Text(
              'No host uses this key yet.',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: AppColors.muted),
            )
          else
            Card(
              child: Column(
                children: [
                  for (final server in users)
                    ListTile(
                      leading: const Icon(Icons.dns_outlined),
                      title: Text(server.label),
                      subtitle: Text('${server.username}@${server.host}'),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.error,
              side: const BorderSide(color: AppColors.error),
            ),
            onPressed: () => _delete(context, ref, record, users.length),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete key'),
          ),
        ],
      ),
    );
  }

  static String _date(DateTime time) {
    final local = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }

  Future<void> _share(
    BuildContext context,
    WidgetRef ref,
    SshKeyRecord record,
  ) async {
    try {
      await ref.read(shareTextProvider)(record.publicKey, record.name);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open the share sheet. $error')),
        );
      }
    }
  }

  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    SshKeyRecord record,
  ) async {
    final name = await TextPromptDialog.show(
      context,
      title: 'Rename key',
      confirmLabel: 'Rename',
      initialText: record.name,
      maxLength: 60,
    );
    if (name == null || !context.mounted) return;
    try {
      await ref.read(keyListProvider.notifier).rename(record.id, name);
    } on VaultException catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    SshKeyRecord record,
    int usedBy,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete key?'),
        content: Text(
          usedBy > 0
              ? '${record.name} is used by $usedBy host${usedBy == 1 ? '' : 's'}. '
                    'Change them first.'
              : 'Delete ${record.name} from this device? The server keeps its '
                    'copy of the public key.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          if (usedBy == 0)
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete'),
            ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(keyListProvider.notifier).delete(record.id);
      navigator.pop();
    } on VaultException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 10),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: AppColors.muted,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Text(label, style: const TextStyle(color: AppColors.muted)),
          const Spacer(),
          Text(value),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.accentSoft,
        borderRadius: BorderRadius.circular(AppRadii.button),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.check_circle, color: AppColors.accent, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _CopyBlock extends StatelessWidget {
  const _CopyBlock({
    super.key,
    required this.text,
    required this.copyLabel,
    this.onShare,
  });

  final String text;
  final String copyLabel;
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 6),
      decoration: BoxDecoration(
        color: AppColors.terminalBackground,
        borderRadius: BorderRadius.circular(AppRadii.button),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SelectableText(
              text,
              style: const TextStyle(
                fontFamily: AppFonts.mono,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (onShare != null)
                TextButton.icon(
                  onPressed: onShare,
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: const Text('Share'),
                ),
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        SnackBar(content: Text('$copyLabel copied')),
                      );
                  }
                },
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
