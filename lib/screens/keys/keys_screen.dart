import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/ssh_key_record.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/screens/keys/add_key_screen.dart';
import 'package:ssh_app/screens/keys/key_detail_screen.dart';
import 'package:ssh_app/theme/tokens.dart';

/// The saved SSH keys, reusable by any host.
class KeysScreen extends ConsumerWidget {
  const KeysScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keys = ref.watch(keyListProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Keys')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'keys-fab',
        onPressed: () => _chooseHowToAdd(context),
        icon: const Icon(Icons.add),
        label: const Text('Add key'),
      ),
      body: keys.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$error', textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => ref.invalidate(keyListProvider),
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
        data: (items) => items.isEmpty
            ? _Empty(onAdd: () => _chooseHowToAdd(context))
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 104),
                children: [
                  for (final key in items) _KeyCard(record: key),
                ],
              ),
      ),
    );
  }

  void _chooseHowToAdd(BuildContext context) {
    void open(KeyAddMode mode) {
      Navigator.of(context).pop();
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => AddKeyScreen(mode: mode)),
      );
    }

    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.auto_awesome, color: AppColors.accent),
              title: const Text('Generate Ed25519'),
              subtitle: const Text('Recommended. Fast and small.'),
              onTap: () => open(KeyAddMode.generate),
            ),
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('Generate RSA 4096'),
              subtitle: const Text('For older servers. Can take a minute.'),
              onTap: () => open(KeyAddMode.generateRsa),
            ),
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('Paste a private key'),
              onTap: () => open(KeyAddMode.paste),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('Import from a file'),
              onTap: () => open(KeyAddMode.file),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _KeyCard extends StatelessWidget {
  const _KeyCard({required this.record});

  final SshKeyRecord record;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => KeyDetailScreen(keyId: record.id),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: AppSizes.avatar,
                  height: AppSizes.avatar,
                  decoration: BoxDecoration(
                    color: AppColors.accentSoft,
                    borderRadius: BorderRadius.circular(AppSizes.avatarRadius),
                  ),
                  child: const Icon(Icons.key, color: AppColors.accent),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        record.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        record.fingerprint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: AppFonts.mono,
                          fontSize: 11,
                          color: AppColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(record.type, style: theme.textTheme.labelMedium),
                    if (record.encrypted)
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Icon(
                          Icons.lock_outline,
                          size: 16,
                          color: AppColors.muted,
                          semanticLabel: 'Protected by a passphrase',
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
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
              child: const Icon(Icons.key_outlined, color: AppColors.accent, size: 30),
            ),
            const SizedBox(height: 16),
            Text('No keys yet', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Generate a key here, or import one, then pick it for any host '
              'instead of pasting it each time.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.muted),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add key'),
            ),
          ],
        ),
      ),
    );
  }
}
