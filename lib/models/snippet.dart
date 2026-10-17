import 'dart:convert';

import 'package:uuid/uuid.dart';

/// How a step knows it is finished.
enum WaitKind {
  /// The command returned (the shell ran it to the end).
  prompt('Prompt returns'),

  /// A given text appeared in the output.
  text('Text appears'),

  /// A fixed time passed.
  seconds('Seconds');

  const WaitKind(this.label);

  final String label;
}

class WaitRule {
  const WaitRule.prompt() : kind = WaitKind.prompt, text = '', seconds = 0;

  const WaitRule.text(this.text) : kind = WaitKind.text, seconds = 0;

  const WaitRule.seconds(this.seconds) : kind = WaitKind.seconds, text = '';

  factory WaitRule.fromJson(Map<String, dynamic> json) {
    final kind = WaitKind.values.where((k) => k.name == json['kind']);
    switch (kind.firstOrNull) {
      case WaitKind.text:
        return WaitRule.text(
          json['text'] is String ? json['text'] as String : '',
        );
      case WaitKind.seconds:
        final value = json['seconds'];
        return WaitRule.seconds(
          value is num ? value.toInt().clamp(0, 3600) : 1,
        );
      default:
        return const WaitRule.prompt();
    }
  }

  final WaitKind kind;

  /// For [WaitKind.text].
  final String text;

  /// For [WaitKind.seconds].
  final int seconds;

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    if (kind == WaitKind.text) 'text': text,
    if (kind == WaitKind.seconds) 'seconds': seconds,
  };

  @override
  bool operator ==(Object other) =>
      other is WaitRule &&
      other.kind == kind &&
      other.text == text &&
      other.seconds == seconds;

  @override
  int get hashCode => Object.hash(kind, text, seconds);
}

class SnippetStep {
  const SnippetStep({
    required this.command,
    this.wait = const WaitRule.prompt(),
    this.timeoutSeconds = defaultTimeoutSeconds,
  });

  factory SnippetStep.fromJson(Map<String, dynamic> json) {
    final timeout = json['timeoutSeconds'];
    return SnippetStep(
      command: json['command'] is String ? json['command'] as String : '',
      wait: json['wait'] is Map
          ? WaitRule.fromJson(Map<String, dynamic>.from(json['wait'] as Map))
          : const WaitRule.prompt(),
      timeoutSeconds: timeout is num
          ? timeout.toInt().clamp(1, 3600)
          : defaultTimeoutSeconds,
    );
  }

  static const defaultTimeoutSeconds = 60;

  final String command;
  final WaitRule wait;

  /// How long to wait for [wait] before the step counts as failed. Not used
  /// for a fixed number of seconds.
  final int timeoutSeconds;

  Map<String, dynamic> toJson() => {
    'command': command,
    'wait': wait.toJson(),
    'timeoutSeconds': timeoutSeconds,
  };

  @override
  bool operator ==(Object other) =>
      other is SnippetStep &&
      other.command == command &&
      other.wait == wait &&
      other.timeoutSeconds == timeoutSeconds;

  @override
  int get hashCode => Object.hash(command, wait, timeoutSeconds);
}

enum VariableType {
  text('Text'),
  choice('Choice'),
  secret('Secret');

  const VariableType(this.label);

  final String label;
}

/// How a `${NAME}` in a snippet is asked for.
class SnippetVariable {
  const SnippetVariable({
    required this.name,
    this.type = VariableType.text,
    this.defaultValue = '',
    this.choices = const [],
  });

  factory SnippetVariable.fromJson(Map<String, dynamic> json) {
    final type = VariableType.values.where((t) => t.name == json['type']);
    final type0 = type.firstOrNull ?? VariableType.text;
    final choices = json['choices'];
    return SnippetVariable(
      name: json['name'] is String ? json['name'] as String : '',
      type: type0,
      // A secret never has a stored value, whatever the file says.
      defaultValue:
          type0 == VariableType.secret || json['defaultValue'] is! String
          ? ''
          : json['defaultValue'] as String,
      choices: choices is List
          ? [
              for (final c in choices)
                if (c is String) c,
            ]
          : const [],
    );
  }

  final String name;
  final VariableType type;

  /// Always empty for [VariableType.secret].
  final String defaultValue;
  final List<String> choices;

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type.name,
    if (type != VariableType.secret && defaultValue.isNotEmpty)
      'defaultValue': defaultValue,
    if (type == VariableType.choice) 'choices': choices,
  };

  @override
  bool operator ==(Object other) =>
      other is SnippetVariable &&
      other.name == name &&
      other.type == type &&
      other.defaultValue == defaultValue &&
      _same(other.choices, choices);

  @override
  int get hashCode =>
      Object.hash(name, type, defaultValue, Object.hashAll(choices));
}

bool _same(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

final _variablePattern = RegExp(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}');

/// The names of the `${NAME}` placeholders in [text], in order, once each.
List<String> detectVariables(Iterable<String> text) {
  final names = <String>[];
  for (final part in text) {
    for (final match in _variablePattern.allMatches(part)) {
      final name = match.group(1)!;
      if (!names.contains(name)) names.add(name);
    }
  }
  return names;
}

/// [command] with every `${NAME}` replaced from [values]. Throws
/// [FormatException] naming the first one that has no value.
String resolveVariables(String command, Map<String, String> values) {
  return command.replaceAllMapped(_variablePattern, (match) {
    final value = values[match.group(1)];
    if (value == null) {
      throw FormatException('No value for \${${match.group(1)}}.');
    }
    return value;
  });
}

/// An ordered list of commands to run in a shell.
class Snippet {
  const Snippet({
    required this.id,
    required this.name,
    required this.steps,
    this.tags = const [],
    this.variables = const [],
    this.stopOnFailure = false,
    this.askFirst = false,
    this.runOnConnect = const [],
    required this.updatedAt,
  });

  factory Snippet.create({
    required String name,
    required List<SnippetStep> steps,
    List<String> tags = const [],
    List<SnippetVariable> variables = const [],
    bool stopOnFailure = false,
    bool askFirst = false,
    DateTime? now,
  }) {
    return Snippet(
      id: const Uuid().v4(),
      name: name,
      steps: steps,
      tags: tags,
      variables: variables,
      stopOnFailure: stopOnFailure,
      askFirst: askFirst,
      updatedAt: (now ?? DateTime.now()).toUtc(),
    );
  }

  factory Snippet.fromJson(Map<String, dynamic> json) {
    List<String> strings(Object? value) => value is List
        ? [
            for (final v in value)
              if (v is String) v,
          ]
        : const [];
    final steps = json['steps'];
    final variables = json['variables'];
    final updated = json['updatedAt'];
    return Snippet(
      id: json['id'] is String && (json['id'] as String).isNotEmpty
          ? json['id'] as String
          : const Uuid().v4(),
      name: json['name'] is String ? json['name'] as String : 'Snippet',
      steps: steps is List
          ? [
              for (final s in steps)
                if (s is Map)
                  SnippetStep.fromJson(Map<String, dynamic>.from(s)),
            ]
          : const [],
      tags: strings(json['tags']),
      variables: variables is List
          ? [
              for (final v in variables)
                if (v is Map)
                  SnippetVariable.fromJson(Map<String, dynamic>.from(v)),
            ]
          : const [],
      stopOnFailure: json['stopOnFailure'] == true,
      askFirst: json['askFirst'] == true,
      runOnConnect: strings(json['runOnConnect']),
      updatedAt: updated is String
          ? DateTime.tryParse(updated)?.toUtc() ?? DateTime.now().toUtc()
          : DateTime.now().toUtc(),
    );
  }

  final String id;
  final String name;
  final List<SnippetStep> steps;
  final List<String> tags;

  /// How placeholders are asked for. A placeholder with no entry here is a
  /// plain text variable.
  final List<SnippetVariable> variables;

  /// Stop at the first step that fails or times out.
  final bool stopOnFailure;

  /// Confirm the resolved commands before running.
  final bool askFirst;

  /// Ids of the hosts this runs on when a shell opens.
  final List<String> runOnConnect;
  final DateTime updatedAt;

  /// The placeholders used by the steps, each with its definition.
  List<SnippetVariable> get allVariables {
    return [
      for (final name in detectVariables(steps.map((s) => s.command)))
        variables.where((v) => v.name == name).firstOrNull ??
            SnippetVariable(name: name),
    ];
  }

  bool get hasSecret => allVariables.any((v) => v.type == VariableType.secret);

  /// Values to start from: each variable's default (secrets start empty).
  Map<String, String> get defaultValues => {
    for (final v in allVariables)
      v.name: v.type == VariableType.choice && v.defaultValue.isEmpty
          ? (v.choices.firstOrNull ?? '')
          : v.defaultValue,
  };

  /// Whether every variable can be filled from its default without asking.
  bool get canRunWithoutAsking => allVariables.isEmpty;

  Snippet copyWith({
    String? name,
    List<SnippetStep>? steps,
    List<String>? tags,
    List<SnippetVariable>? variables,
    bool? stopOnFailure,
    bool? askFirst,
    List<String>? runOnConnect,
    DateTime? updatedAt,
  }) {
    return Snippet(
      id: id,
      name: name ?? this.name,
      steps: steps ?? this.steps,
      tags: tags ?? this.tags,
      variables: variables ?? this.variables,
      stopOnFailure: stopOnFailure ?? this.stopOnFailure,
      askFirst: askFirst ?? this.askFirst,
      runOnConnect: runOnConnect ?? this.runOnConnect,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'steps': [for (final s in steps) s.toJson()],
    'tags': tags,
    'variables': [for (final v in variables) v.toJson()],
    'stopOnFailure': stopOnFailure,
    'askFirst': askFirst,
    'runOnConnect': runOnConnect,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  @override
  String toString() => 'Snippet($id, $name, ${steps.length} steps)';
}

/// Snippets as a file other devices can import.
abstract final class SnippetFile {
  static const version = 1;

  /// JSON for [snippets]. Host ids are left out, since they mean nothing on
  /// another device; secrets never have values.
  static String export(List<Snippet> snippets) {
    return const JsonEncoder.withIndent('  ').convert({
      'app': 'ssh_app',
      'version': version,
      'snippets': [
        for (final snippet in snippets)
          (snippet.copyWith(runOnConnect: const []).toJson()..remove('id')),
      ],
    });
  }

  /// Reads a file made by [export]. Every snippet gets a new id. Throws
  /// [FormatException] with a message safe to show.
  static List<Snippet> import(String text, {DateTime? now}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const FormatException('This file is not valid JSON.');
    }
    final list = decoded is Map ? decoded['snippets'] : decoded;
    if (list is! List) {
      throw const FormatException('This file has no snippets in it.');
    }
    final imported = <Snippet>[];
    for (final item in list) {
      if (item is! Map) continue;
      final json = Map<String, dynamic>.from(item)
        ..remove('id')
        ..remove('runOnConnect');
      final snippet = Snippet.fromJson(json);
      if (snippet.steps.isEmpty) continue;
      imported.add(
        snippet.copyWith(updatedAt: (now ?? DateTime.now()).toUtc()),
      );
    }
    if (imported.isEmpty) {
      throw const FormatException('This file has no snippets in it.');
    }
    return imported;
  }
}

extension SnippetRun on Snippet {
  /// The steps with every placeholder replaced from [values]. Throws
  /// [FormatException] for a placeholder with no value.
  List<({String command, WaitRule wait, int timeoutSeconds})> resolvedSteps(
    Map<String, String> values,
  ) {
    return [
      for (final step in steps)
        (
          command: resolveVariables(step.command, values),
          wait: WaitRule.fromJson({
            ...step.wait.toJson(),
            if (step.wait.kind == WaitKind.text)
              'text': resolveVariables(step.wait.text, values),
          }),
          timeoutSeconds: step.timeoutSeconds,
        ),
    ];
  }

  /// The commands for showing before they run: secret values are hidden.
  List<String> previewCommands(Map<String, String> values) {
    final shown = {
      for (final entry in values.entries)
        entry.key:
            allVariables.where((v) => v.name == entry.key).firstOrNull?.type ==
                VariableType.secret
            ? '••••••'
            : entry.value,
    };
    return [for (final step in steps) resolveVariables(step.command, shown)];
  }
}
