import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/snippet.dart';
import 'package:ssh_app/providers/snippet_providers.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/theme/tokens.dart';

/// The command that reattaches to a tmux session, or starts one, so work
/// survives a dropped connection.
const tmuxCommand = 'tmux new -A -s main';

/// Creates or edits a snippet.
class SnippetEditScreen extends ConsumerStatefulWidget {
  const SnippetEditScreen({super.key, this.snippet});

  final Snippet? snippet;

  @override
  ConsumerState<SnippetEditScreen> createState() => _SnippetEditScreenState();
}

class _StepFields {
  _StepFields(SnippetStep step)
    : command = TextEditingController(text: step.command),
      waitText = TextEditingController(text: step.wait.text),
      seconds = TextEditingController(
        text: step.wait.kind == WaitKind.seconds ? '${step.wait.seconds}' : '1',
      ),
      timeout = TextEditingController(text: '${step.timeoutSeconds}'),
      kind = step.wait.kind;

  final TextEditingController command;
  final TextEditingController waitText;
  final TextEditingController seconds;
  final TextEditingController timeout;
  WaitKind kind;

  SnippetStep toStep() {
    final wait = switch (kind) {
      WaitKind.prompt => const WaitRule.prompt(),
      WaitKind.text => WaitRule.text(waitText.text),
      WaitKind.seconds => WaitRule.seconds(
        (int.tryParse(seconds.text.trim()) ?? 1).clamp(0, 3600),
      ),
    };
    return SnippetStep(
      command: command.text.trim(),
      wait: wait,
      timeoutSeconds:
          (int.tryParse(timeout.text.trim()) ??
                  SnippetStep.defaultTimeoutSeconds)
              .clamp(1, 3600),
    );
  }

  void dispose() {
    command.dispose();
    waitText.dispose();
    seconds.dispose();
    timeout.dispose();
  }
}

class _SnippetEditScreenState extends ConsumerState<SnippetEditScreen> {
  late final _name = TextEditingController(text: widget.snippet?.name ?? '');
  late final _tags = TextEditingController(
    text: widget.snippet?.tags.join(', ') ?? '',
  );
  late final List<_StepFields> _steps = [
    for (final step
        in widget.snippet?.steps ?? const [SnippetStep(command: '')])
      _StepFields(step),
  ];
  late var _stopOnFailure = widget.snippet?.stopOnFailure ?? false;
  late var _askFirst = widget.snippet?.askFirst ?? false;
  late final _onConnect = {...?widget.snippet?.runOnConnect};

  /// How each placeholder is asked for, keyed by name.
  late final Map<String, SnippetVariable> _variables = {
    for (final v in widget.snippet?.variables ?? const <SnippetVariable>[])
      v.name: v,
  };
  final _defaults = <String, TextEditingController>{};
  final _choices = <String, TextEditingController>{};
  String? _error;
  var _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _tags.dispose();
    for (final step in _steps) {
      step.dispose();
    }
    for (final c in [..._defaults.values, ..._choices.values]) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> get _detected =>
      detectVariables(_steps.map((s) => s.command.text));

  SnippetVariable _variable(String name) =>
      _variables[name] ?? SnippetVariable(name: name);

  TextEditingController _defaultField(String name) => _defaults.putIfAbsent(
    name,
    () => TextEditingController(text: _variable(name).defaultValue),
  );

  TextEditingController _choicesField(String name) => _choices.putIfAbsent(
    name,
    () => TextEditingController(text: _variable(name).choices.join(', ')),
  );

  /// The variable definitions as currently edited, for the placeholders in
  /// use.
  List<SnippetVariable> _collectVariables() {
    return [
      for (final name in _detected)
        SnippetVariable(
          name: name,
          type: _variable(name).type,
          defaultValue: _variable(name).type == VariableType.secret
              ? ''
              : _defaultField(name).text,
          choices: [
            for (final c in _choicesField(name).text.split(','))
              if (c.trim().isNotEmpty) c.trim(),
          ],
        ),
    ];
  }

  Future<void> _save() async {
    final steps = [for (final s in _steps) s.toStep()];
    String? error;
    if (_name.text.trim().isEmpty) {
      error = 'Give the snippet a name.';
    } else if (steps.every((s) => s.command.isEmpty)) {
      error = 'Add at least one command.';
    } else if (steps.any((s) => s.command.isEmpty)) {
      error = 'Every step needs a command. Remove the empty ones.';
    } else if (steps.any(
      (s) => s.wait.kind == WaitKind.text && s.wait.text.isEmpty,
    )) {
      error = 'A step that waits for text needs the text to wait for.';
    } else {
      final variables = _collectVariables();
      for (final v in variables) {
        if (v.type == VariableType.choice && v.choices.isEmpty) {
          error =
              '\${${v.name}} is a choice. Enter its options, separated by commas.';
          break;
        }
      }
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final existing = widget.snippet;
    final tags = [
      for (final t in _tags.text.split(','))
        if (t.trim().isNotEmpty) t.trim(),
    ];
    final base =
        existing ?? Snippet.create(name: _name.text.trim(), steps: steps);
    await ref
        .read(snippetListProvider.notifier)
        .save(
          base.copyWith(
            name: _name.text.trim(),
            steps: steps,
            tags: tags,
            variables: _collectVariables(),
            stopOnFailure: _stopOnFailure,
            askFirst: _askFirst,
            runOnConnect: _onConnect.toList(),
          ),
        );
    if (mounted) Navigator.of(context).pop();
  }

  void _move(int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= _steps.length) return;
    setState(() => _steps.insert(target, _steps.removeAt(index)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hosts = ref.watch(serverListProvider).asData?.value ?? const [];
    final variables = _detected;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.snippet == null ? 'New snippet' : 'Edit snippet'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          if (_error != null)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.errorSoft,
                borderRadius: BorderRadius.circular(AppRadii.button),
              ),
              child: Text(
                _error!,
                style: const TextStyle(color: AppColors.error),
              ),
            ),
          TextField(
            controller: _name,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tags,
            decoration: const InputDecoration(
              labelText: 'Tags',
              helperText: 'Separated by commas',
            ),
          ),
          _header('Steps'),
          for (final (i, step) in _steps.indexed) _stepCard(i, step),
          OutlinedButton.icon(
            onPressed: () => setState(
              () => _steps.add(_StepFields(const SnippetStep(command: ''))),
            ),
            icon: const Icon(Icons.add),
            label: const Text('Add step'),
          ),
          const SizedBox(height: 4),
          Text(
            r'Use ${NAME} for a value asked when it runs. Do not end a command '
            'with a # comment.',
            style: theme.textTheme.bodySmall,
          ),
          if (variables.isNotEmpty) ...[
            _header('Variables'),
            for (final name in variables) _variableCard(name),
          ],
          _header('When it runs'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Stop at the first failed step'),
                  subtitle: const Text(
                    'Uses each command’s exit code. Needs a POSIX shell.',
                  ),
                  value: _stopOnFailure,
                  onChanged: (on) => setState(() => _stopOnFailure = on),
                ),
                const Divider(),
                SwitchListTile(
                  title: const Text('Ask before running'),
                  subtitle: const Text('Show the commands and confirm first'),
                  value: _askFirst,
                  onChanged: (on) => setState(() => _askFirst = on),
                ),
              ],
            ),
          ),
          _header('Run automatically on connect'),
          if (hosts.isEmpty)
            const Text('Add a host to run this when it connects.')
          else
            Card(
              child: Column(
                children: [
                  for (final host in hosts)
                    CheckboxListTile(
                      key: ValueKey('connect-${host.id}'),
                      title: Text(host.label),
                      subtitle: Text('${host.username}@${host.host}'),
                      value: _onConnect.contains(host.id),
                      onChanged: (on) => setState(() {
                        on == true
                            ? _onConnect.add(host.id)
                            : _onConnect.remove(host.id);
                      }),
                    ),
                ],
              ),
            ),
          if (_onConnect.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.accentSoft,
                borderRadius: BorderRadius.circular(AppRadii.button),
              ),
              child: Row(
                children: [
                  const Icon(Icons.lightbulb_outline, color: AppColors.accent),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Tip: start with tmux so your work survives a dropped '
                      'connection.',
                    ),
                  ),
                  if (!_steps.any((s) => s.command.text.trim() == tmuxCommand))
                    TextButton(
                      onPressed: () => setState(
                        () => _steps.insert(
                          0,
                          _StepFields(const SnippetStep(command: tmuxCommand)),
                        ),
                      ),
                      child: const Text('Add tmux'),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _header(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
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

  Widget _stepCard(int index, _StepFields step) {
    return Card(
      key: ObjectKey(step),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Step ${index + 1}',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Move up',
                  icon: const Icon(Icons.arrow_upward, size: 20),
                  onPressed: index == 0 ? null : () => _move(index, -1),
                ),
                IconButton(
                  tooltip: 'Move down',
                  icon: const Icon(Icons.arrow_downward, size: 20),
                  onPressed: index == _steps.length - 1
                      ? null
                      : () => _move(index, 1),
                ),
                IconButton(
                  tooltip: 'Remove step',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: _steps.length == 1
                      ? null
                      : () => setState(() => _steps.removeAt(index).dispose()),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    key: ValueKey('step-command-$index'),
                    controller: step.command,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: const TextStyle(fontFamily: AppFonts.mono),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Command'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<WaitKind>(
                    key: ValueKey('step-wait-$index-${step.kind}'),
                    initialValue: step.kind,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Then wait until',
                    ),
                    items: [
                      for (final kind in WaitKind.values)
                        DropdownMenuItem(value: kind, child: Text(kind.label)),
                    ],
                    onChanged: (kind) =>
                        setState(() => step.kind = kind ?? WaitKind.prompt),
                  ),
                  if (step.kind == WaitKind.text) ...[
                    const SizedBox(height: 12),
                    TextField(
                      key: ValueKey('step-text-$index'),
                      controller: step.waitText,
                      decoration: const InputDecoration(
                        labelText: 'Text to wait for',
                      ),
                    ),
                  ],
                  if (step.kind == WaitKind.seconds) ...[
                    const SizedBox(height: 12),
                    TextField(
                      key: ValueKey('step-seconds-$index'),
                      controller: step.seconds,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Seconds'),
                    ),
                  ],
                  if (step.kind != WaitKind.seconds) ...[
                    const SizedBox(height: 12),
                    TextField(
                      key: ValueKey('step-timeout-$index'),
                      controller: step.timeout,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Timeout (seconds)',
                        helperText: 'The step fails if this runs out',
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _variableCard(String name) {
    final variable = _variable(name);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '\${$name}',
              style: const TextStyle(fontFamily: AppFonts.mono),
            ),
            const SizedBox(height: 10),
            SegmentedButton<VariableType>(
              showSelectedIcon: false,
              segments: [
                for (final type in VariableType.values)
                  ButtonSegment(value: type, label: Text(type.label)),
              ],
              selected: {variable.type},
              onSelectionChanged: (selection) => setState(() {
                _variables[name] = SnippetVariable(
                  name: name,
                  type: selection.first,
                );
              }),
            ),
            const SizedBox(height: 10),
            if (variable.type == VariableType.secret)
              Text(
                'Asked each time you run it. Never saved. Do not use this for a '
                'sudo password.',
                style: Theme.of(context).textTheme.bodySmall,
              )
            else ...[
              if (variable.type == VariableType.choice) ...[
                TextField(
                  key: ValueKey('choices-$name'),
                  controller: _choicesField(name),
                  decoration: const InputDecoration(
                    labelText: 'Options',
                    helperText: 'Separated by commas',
                  ),
                ),
                const SizedBox(height: 10),
              ],
              TextField(
                key: ValueKey('default-$name'),
                controller: _defaultField(name),
                decoration: const InputDecoration(labelText: 'Default value'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
