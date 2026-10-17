import 'package:flutter/material.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/snippet.dart';
import 'package:ssh_app/theme/tokens.dart';

/// What the user chose in the run sheet.
class RunRequest {
  const RunRequest({required this.values, required this.hosts});

  final Map<String, String> values;

  /// The hosts to run on. Empty when running in the open terminal.
  final List<ServerConfig> hosts;
}

/// Asks for variables and hosts, previews the commands, and returns the
/// choice, or null if the user backs out.
///
/// With [hosts] null the snippet runs in the terminal that is open, so there
/// is nothing to pick. Secret values live only in this sheet's fields and are
/// shown masked in the preview; they are not saved anywhere.
Future<RunRequest?> showRunSheet(
  BuildContext context, {
  required Snippet snippet,
  List<ServerConfig>? hosts,
}) {
  return showModalBottomSheet<RunRequest>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => RunSheet(snippet: snippet, hosts: hosts),
  );
}

class RunSheet extends StatefulWidget {
  const RunSheet({super.key, required this.snippet, this.hosts});

  final Snippet snippet;
  final List<ServerConfig>? hosts;

  @override
  State<RunSheet> createState() => _RunSheetState();
}

class _RunSheetState extends State<RunSheet> {
  late final Map<String, TextEditingController> _fields = {
    for (final entry in widget.snippet.defaultValues.entries)
      entry.key: TextEditingController(text: entry.value),
  };
  final _chosen = <String>{};
  final _showSecret = <String>{};
  var _tried = false;

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  Map<String, String> get _values => {
    for (final entry in _fields.entries) entry.key: entry.value.text,
  };

  bool get _valid =>
      _values.values.every((v) => v.isNotEmpty) &&
      (widget.hosts == null || _chosen.isNotEmpty);

  void _run() {
    setState(() => _tried = true);
    if (!_valid) return;
    Navigator.of(context).pop(
      RunRequest(
        values: _values,
        hosts: [
          for (final host in widget.hosts ?? const <ServerConfig>[])
            if (_chosen.contains(host.id)) host,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snippet = widget.snippet;
    final hosts = widget.hosts;
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    final preview = snippet.previewCommands(_values);
    return Padding(
      padding: EdgeInsets.only(bottom: insets),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(snippet.name, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              '${snippet.steps.length} step${snippet.steps.length == 1 ? '' : 's'}'
              '${snippet.stopOnFailure ? ' · stops at the first failure' : ''}',
              style: theme.textTheme.bodySmall,
            ),
            for (final variable in snippet.allVariables) ...[
              const SizedBox(height: 16),
              _field(variable),
            ],
            if (hosts != null) ...[
              const SizedBox(height: 16),
              Text('Run on', style: theme.textTheme.titleSmall),
              if (hosts.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Add a host first.'),
                ),
              for (final host in hosts)
                CheckboxListTile(
                  key: ValueKey('host-${host.id}'),
                  contentPadding: EdgeInsets.zero,
                  value: _chosen.contains(host.id),
                  title: Text(host.label),
                  subtitle: Text('${host.username}@${host.host}'),
                  onChanged: (on) => setState(() {
                    if (on == true) {
                      _chosen.add(host.id);
                    } else {
                      _chosen.remove(host.id);
                    }
                  }),
                ),
              if (_tried && _chosen.isEmpty)
                const Text(
                  'Pick at least one host.',
                  style: TextStyle(color: AppColors.error),
                ),
            ],
            const SizedBox(height: 8),
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: ValueKey('preview-${snippet.askFirst}'),
                initiallyExpanded: snippet.askFirst,
                tilePadding: EdgeInsets.zero,
                title: Text(
                  snippet.askFirst ? 'Commands to run' : 'Preview commands',
                  style: const TextStyle(color: AppColors.accent),
                ),
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.terminalBackground,
                      borderRadius: BorderRadius.circular(AppRadii.button),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final (i, command) in preview.indexed)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              '${i + 1}. $command',
                              key: ValueKey('preview-$i'),
                              style: const TextStyle(
                                fontFamily: AppFonts.mono,
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (snippet.hasSecret)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Secret values are used for this run only and are never saved.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _run,
                    child: Text(
                      snippet.askFirst ? 'Run these commands' : 'Run',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(SnippetVariable variable) {
    final controller = _fields[variable.name]!;
    final error = _tried && controller.text.isEmpty ? 'Enter a value.' : null;
    switch (variable.type) {
      case VariableType.choice:
        return DropdownButtonFormField<String>(
          key: ValueKey('var-${variable.name}'),
          initialValue: controller.text.isEmpty ? null : controller.text,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: variable.name,
            errorText: error,
          ),
          items: [
            for (final choice in variable.choices)
              DropdownMenuItem(value: choice, child: Text(choice)),
          ],
          onChanged: (value) => setState(() => controller.text = value ?? ''),
        );
      case VariableType.secret:
        final shown = _showSecret.contains(variable.name);
        return TextField(
          key: ValueKey('var-${variable.name}'),
          controller: controller,
          obscureText: !shown,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: variable.name,
            helperText: 'Secret: asked each time, not saved',
            errorText: error,
            suffixIcon: IconButton(
              tooltip: shown ? 'Hide' : 'Show',
              icon: Icon(
                shown
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
              onPressed: () => setState(() {
                shown
                    ? _showSecret.remove(variable.name)
                    : _showSecret.add(variable.name);
              }),
            ),
          ),
        );
      case VariableType.text:
        return TextField(
          key: ValueKey('var-${variable.name}'),
          controller: controller,
          autocorrect: false,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: variable.name,
            errorText: error,
          ),
        );
    }
  }
}
