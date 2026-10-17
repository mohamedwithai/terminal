import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/providers/sftp_providers.dart';
import 'package:ssh_app/screens/files/sftp_browser_controller.dart';
import 'package:ssh_app/screens/widgets/text_prompt_dialog.dart';
import 'package:ssh_app/services/sftp/remote_file_system.dart';
import 'package:ssh_app/services/ssh/ssh_connection_session.dart';
import 'package:ssh_app/theme/tokens.dart';

String _date(DateTime time) {
  final local = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

/// Browses the files of a host over SFTP: folders, sorting, download, upload,
/// rename, delete and new folders. It uses an open terminal's connection
/// when there is one.
class SftpBrowserScreen extends ConsumerStatefulWidget {
  const SftpBrowserScreen({super.key, required this.server, this.reuse});

  final ServerConfig server;

  /// The terminal session whose connection to share.
  final SSHConnectionSession? reuse;

  @override
  ConsumerState<SftpBrowserScreen> createState() => _SftpBrowserScreenState();
}

class _SftpBrowserScreenState extends ConsumerState<SftpBrowserScreen> {
  late final SftpBrowserController _controller;

  @override
  void initState() {
    super.initState();
    _controller = SftpBrowserController(
      opener: ref.read(sftpOpenerProvider),
      server: widget.server,
      reuse: widget.reuse,
      saveDownload: ref.read(fileSaverProvider),
    )..addListener(_showNotice);
    unawaited(_controller.start());
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_showNotice)
      ..dispose();
    super.dispose();
  }

  void _showNotice() {
    final message = _controller.takeNotice();
    if (message != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _newFolder() async {
    final name = await TextPromptDialog.show(
      context,
      title: 'New folder',
      confirmLabel: 'Create',
      validator: (text) => _validateName(text),
    );
    if (name != null) await _controller.createFolder(name.trim());
  }

  String? _validateName(String text, {String? current}) {
    final problem = nameProblem(text);
    if (problem != null) return problem;
    final name = text.trim();
    if (name != current && _controller.entries.any((e) => e.name == name)) {
      return 'There is already something called "$name" here.';
    }
    return null;
  }

  Future<void> _rename(RemoteEntry entry) async {
    final name = await TextPromptDialog.show(
      context,
      title: 'Rename',
      confirmLabel: 'Rename',
      initialText: entry.name,
      validator: (text) => _validateName(text, current: entry.name),
    );
    if (name != null && name.trim() != entry.name) {
      await _controller.rename(entry, name.trim());
    }
  }

  Future<void> _delete(RemoteEntry entry) async {
    final inside = entry.isDirectory ? await _controller.countInside(entry) : 0;
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(entry.isDirectory ? 'Delete folder?' : 'Delete file?'),
        content: Text(
          entry.isDirectory
              ? inside == 0
                    ? 'Delete the empty folder "${entry.name}"?'
                    : 'Delete "${entry.name}" and the $inside '
                          'item${inside == 1 ? '' : 's'} inside it? This '
                          'cannot be undone.'
              : 'Delete "${entry.name}" from ${widget.server.label}? This '
                    'cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: AppColors.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _controller.delete(entry);
  }

  Future<void> _upload() async {
    final List<UploadFile> files;
    try {
      files = await ref.read(uploadPickerProvider)();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open the file picker. $error')),
        );
      }
      return;
    }
    if (files.isEmpty || !mounted) return;
    final existing = {for (final e in _controller.entries) e.name};
    final clashes = [
      for (final f in files)
        if (existing.contains(f.name)) f.name,
    ];
    if (clashes.isNotEmpty) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            clashes.length == 1 ? 'Replace this file?' : 'Replace these files?',
          ),
          content: Text(
            '${clashes.join(', ')} already '
            '${clashes.length == 1 ? 'exists' : 'exist'} in this folder. '
            'Uploading replaces ${clashes.length == 1 ? 'it' : 'them'}.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (replace != true) return;
    }
    await _controller.upload(files);
  }

  void _openEntry(RemoteEntry entry) {
    if (entry.isDirectory) {
      unawaited(_controller.open(joinRemote(_controller.path, entry.name)));
    } else {
      _showActions(entry);
    }
  }

  void _showActions(RemoteEntry entry) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (entry.size != null) formatSize(entry.size!),
                      if (entry.modified != null) _date(entry.modified!),
                      if (entry.permissions != null) entry.permissions!,
                    ].join(' · '),
                    style: Theme.of(sheetContext).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (!entry.isDirectory)
              ListTile(
                key: const ValueKey('action-download'),
                leading: const Icon(Icons.download),
                title: const Text('Download'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _controller.download(entry);
                },
              ),
            ListTile(
              key: const ValueKey('action-rename'),
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(_rename(entry));
              },
            ),
            ListTile(
              key: const ValueKey('action-delete'),
              leading: const Icon(Icons.delete_outline, color: AppColors.error),
              title: const Text(
                'Delete',
                style: TextStyle(color: AppColors.error),
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(_delete(entry));
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirmLeaveWithTransfers() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Transfers are still running'),
        content: const Text('Leave and cancel them?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Stay'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Cancel transfers'),
          ),
        ],
      ),
    );
    return leave == true;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final c = _controller;
        return PopScope(
          // Back goes up a folder first, then leaves.
          canPop: !c.canGoUp && !c.hasRunningTransfer,
          onPopInvokedWithResult: (didPop, result) async {
            if (didPop) return;
            if (c.canGoUp) {
              await c.up();
              return;
            }
            if (await _confirmLeaveWithTransfers() && context.mounted) {
              Navigator.of(context).pop();
            }
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text(widget.server.label),
              actions: [
                IconButton(
                  tooltip: 'Up one folder',
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: c.status == BrowserStatus.ready && c.canGoUp
                      ? () => unawaited(c.up())
                      : null,
                ),
                IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                  onPressed: c.status == BrowserStatus.ready
                      ? () => unawaited(c.refresh())
                      : null,
                ),
                PopupMenuButton<Object>(
                  tooltip: 'More',
                  onSelected: (value) {
                    if (value == 'folder') {
                      unawaited(_newFolder());
                    } else if (value is SortField) {
                      c.setSort(value);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'folder',
                      child: ListTile(
                        leading: Icon(Icons.create_new_folder_outlined),
                        title: Text('New folder'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    const PopupMenuDivider(),
                    for (final field in SortField.values)
                      PopupMenuItem(
                        value: field,
                        child: ListTile(
                          leading: Icon(
                            field == c.sortField
                                ? (c.descending
                                      ? Icons.arrow_downward
                                      : Icons.arrow_upward)
                                : Icons.sort,
                          ),
                          title: Text('Sort by ${field.label.toLowerCase()}'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                  ],
                ),
              ],
            ),
            floatingActionButton: c.status == BrowserStatus.ready
                ? FloatingActionButton.extended(
                    heroTag: 'files-fab',
                    onPressed: _upload,
                    icon: const Icon(Icons.upload),
                    label: const Text('Upload'),
                  )
                : null,
            body: Column(
              children: [
                if (c.status == BrowserStatus.ready)
                  _Breadcrumbs(controller: c),
                if (c.loading) const LinearProgressIndicator(minHeight: 2),
                Expanded(child: _body(c)),
              ],
            ),
            // In the bottom bar, so the Upload button floats above it and
            // never covers a Cancel or Dismiss.
            bottomNavigationBar: c.transfers.isEmpty
                ? null
                : _Transfers(controller: c),
          ),
        );
      },
    );
  }

  Widget _body(SftpBrowserController c) {
    switch (c.status) {
      case BrowserStatus.opening:
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text('Opening files...'),
            ],
          ),
        );
      case BrowserStatus.failed:
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline,
                  color: AppColors.error,
                  size: 36,
                ),
                const SizedBox(height: 12),
                Text(
                  c.error ?? "Couldn't open the files.",
                  key: const ValueKey('files-error'),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => unawaited(c.start()),
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        );
      case BrowserStatus.ready:
        final entries = c.entries;
        if (entries.isEmpty) {
          return const Center(
            child: Text('This folder is empty.', key: ValueKey('files-empty')),
          );
        }
        return RefreshIndicator(
          onRefresh: c.refresh,
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              return ListTile(
                key: ValueKey('entry-${entry.name}'),
                leading: Icon(
                  entry.isDirectory
                      ? Icons.folder
                      : entry.isLink
                      ? Icons.link
                      : Icons.insert_drive_file_outlined,
                  color: entry.isDirectory ? AppColors.warn : AppColors.muted,
                ),
                title: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  [
                    if (entry.size != null) formatSize(entry.size!),
                    if (entry.modified != null) _date(entry.modified!),
                  ].join(' · '),
                ),
                trailing: IconButton(
                  tooltip: 'Options for ${entry.name}',
                  icon: const Icon(Icons.more_vert, color: AppColors.muted),
                  onPressed: () => _showActions(entry),
                ),
                onTap: () => _openEntry(entry),
                onLongPress: () => _showActions(entry),
              );
            },
          ),
        );
    }
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.controller});

  final SftpBrowserController controller;

  @override
  Widget build(BuildContext context) {
    final crumbs = breadcrumbs(controller.path);
    return Container(
      height: 44,
      decoration: const BoxDecoration(
        color: AppColors.bar,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        // The end of a long path is the part that matters.
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          Row(
            children: [
              for (final (i, crumb) in crumbs.indexed) ...[
                if (i > 0)
                  const Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: AppColors.muted,
                  ),
                InkWell(
                  key: ValueKey('crumb-${crumb.path}'),
                  borderRadius: BorderRadius.circular(AppRadii.key),
                  onTap: i == crumbs.length - 1
                      ? null
                      : () => unawaited(controller.open(crumb.path)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 10,
                    ),
                    child: Text(
                      crumb.name,
                      style: TextStyle(
                        fontFamily: AppFonts.mono,
                        fontSize: 13,
                        fontWeight: i == crumbs.length - 1
                            ? FontWeight.w700
                            : FontWeight.w400,
                        color: i == crumbs.length - 1
                            ? AppColors.text
                            : AppColors.accent,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Transfers extends StatelessWidget {
  const _Transfers({required this.controller});

  final SftpBrowserController controller;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.3,
        ),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: SafeArea(
          top: false,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final transfer in controller.transfers)
                _TransferTile(
                  key: ValueKey('transfer-${transfer.id}'),
                  transfer: transfer,
                  onCancel: () => controller.cancelTransfer(transfer),
                  onDismiss: () => controller.dismissTransfer(transfer),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TransferTile extends StatelessWidget {
  const _TransferTile({
    super.key,
    required this.transfer,
    required this.onCancel,
    required this.onDismiss,
  });

  final Transfer transfer;
  final VoidCallback onCancel;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final running = transfer.status == TransferStatus.running;
    final verb = transfer.isUpload ? 'Uploading' : 'Downloading';
    final status = switch (transfer.status) {
      TransferStatus.running =>
        '$verb ${formatSize(transfer.bytes)}'
            '${transfer.total == null ? '' : ' of ${formatSize(transfer.total!)}'}',
      TransferStatus.done => transfer.isUpload ? 'Uploaded' : 'Saved',
      TransferStatus.failed => transfer.message ?? 'Failed',
      TransferStatus.cancelled => transfer.message ?? 'Cancelled',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
      child: Row(
        children: [
          Icon(
            transfer.isUpload ? Icons.upload : Icons.download,
            size: 20,
            color: switch (transfer.status) {
              TransferStatus.failed => AppColors.error,
              TransferStatus.done => AppColors.accent,
              _ => AppColors.muted,
            },
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  transfer.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  status,
                  key: ValueKey('transfer-status-${transfer.id}'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (running) ...[
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    key: ValueKey('transfer-bar-${transfer.id}'),
                    value: transfer.fraction,
                    minHeight: 4,
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: running ? 'Cancel' : 'Dismiss',
            icon: Icon(running ? Icons.stop_circle_outlined : Icons.close),
            onPressed: running ? onCancel : onDismiss,
          ),
        ],
      ),
    );
  }
}
