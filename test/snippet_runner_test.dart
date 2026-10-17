import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/models/snippet.dart';
import 'package:ssh_app/services/snippets/marker_filter.dart';
import 'package:ssh_app/services/snippets/snippet_runner.dart';

/// A shell that echoes what it is sent, runs it from [script] and prints
/// the exit code marker the way `command;echo __RC_x=$?` would.
class SimShell {
  SimShell(this.script, {this.chunkSize});

  /// Command to (output, exit code). Anything else prints nothing, code 0.
  final Map<String, (String, int)> script;

  /// Deliver output in pieces of this size, to test split markers.
  final int? chunkSize;
  late SnippetRunner runner;
  final display = StringBuffer();
  final written = <String>[];

  void write(String text) {
    written.add(text);
    final line = text.endsWith('\r')
        ? text.substring(0, text.length - 1)
        : text;
    final marker = RegExp(r';echo __RC_(\w+)=\$\?$').firstMatch(line);
    final command = marker == null ? line : line.substring(0, marker.start);
    final (output, code) = script[command] ?? ('', 0);
    final reply = StringBuffer('$line\r\n');
    if (output.isNotEmpty) reply.write('$output\r\n');
    if (marker != null) reply.write('__RC_${marker.group(1)}=$code\r\n');
    reply.write(r'$ ');
    _deliver(reply.toString());
  }

  void _deliver(String text) {
    final size = chunkSize;
    if (size == null) {
      display.write(runner.feed(text));
      return;
    }
    for (var i = 0; i < text.length; i += size) {
      display.write(runner.feed(text.substring(i, min(i + size, text.length))));
    }
  }

  /// Output that arrives later, as from a long-running command.
  void say(String text) => display.write(runner.feed(text));
}

SnippetRunner makeRunner(SimShell shell) {
  final runner = SnippetRunner(write: shell.write, random: Random(1));
  shell.runner = runner;
  return runner;
}

void main() {
  group('variables', () {
    test('placeholders are found once each, in order', () {
      expect(
        detectVariables([
          r'scp ${FILE} ${HOST}:~',
          r'echo ${FILE} $HOME ${1bad}',
        ]),
        ['FILE', 'HOST'],
      );
    });

    test('values replace every occurrence; a missing one is named', () {
      expect(resolveVariables(r'cp ${A} ${A}.bak', {'A': 'x'}), 'cp x x.bak');
      expect(
        () => resolveVariables(r'echo ${NOPE}', {}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'm',
            contains('NOPE'),
          ),
        ),
      );
    });

    test('variables get their definitions; the rest are text', () {
      final snippet = Snippet.create(
        name: 'deploy',
        steps: const [
          SnippetStep(command: r'deploy ${ENV} --token ${TOKEN} ${NOTE}'),
        ],
        variables: const [
          SnippetVariable(
            name: 'ENV',
            type: VariableType.choice,
            choices: ['staging', 'prod'],
          ),
          SnippetVariable(
            name: 'TOKEN',
            type: VariableType.secret,
            defaultValue: 'oops',
          ),
        ],
      );

      final all = snippet.allVariables;
      expect(all.map((v) => v.name), ['ENV', 'TOKEN', 'NOTE']);
      expect(all[2].type, VariableType.text);
      expect(snippet.hasSecret, isTrue);
      expect(snippet.defaultValues, {
        'ENV': 'staging',
        'TOKEN': 'oops',
        'NOTE': '',
      });
    });

    test('a secret is never written out with a value', () {
      final json = const SnippetVariable(
        name: 'PW',
        type: VariableType.secret,
        defaultValue: 'hunter2',
      ).toJson();
      expect(json.containsKey('defaultValue'), isFalse);
      expect(
        SnippetVariable.fromJson({
          'name': 'PW',
          'type': 'secret',
          'defaultValue': 'x',
        }).defaultValue,
        isEmpty,
      );
    });
  });

  group('snippet file', () {
    test(
      'export then import keeps steps and variables, drops ids and hosts',
      () {
        final snippet = Snippet.create(
          name: 'Update',
          steps: const [
            SnippetStep(command: 'sudo apt update'),
            SnippetStep(
              command: 'tail -f log',
              wait: WaitRule.text('ready'),
              timeoutSeconds: 5,
            ),
            SnippetStep(command: 'sleep 1', wait: WaitRule.seconds(2)),
          ],
          tags: ['ops'],
          stopOnFailure: true,
          askFirst: true,
        ).copyWith(runOnConnect: ['host-1']);

        final text = SnippetFile.export([snippet]);
        expect(text, isNot(contains('host-1')));
        final imported = SnippetFile.import(text).single;

        expect(imported.id, isNot(snippet.id));
        expect(imported.name, 'Update');
        expect(imported.steps, snippet.steps);
        expect(imported.stopOnFailure, isTrue);
        expect(imported.askFirst, isTrue);
        expect(imported.runOnConnect, isEmpty);
        expect(imported.tags, ['ops']);
      },
    );

    test('bad files are refused with a clear message', () {
      expect(() => SnippetFile.import('nope'), throwsA(isA<FormatException>()));
      expect(
        () => SnippetFile.import('{"snippets": []}'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => SnippetFile.import('{"x": 1}'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('marker filter', () {
    String run(String nonce, List<String> chunks, List<int> codes) {
      final filter = MarkerFilter(nonce, onExitCode: codes.add);
      final out = StringBuffer();
      for (final chunk in chunks) {
        out.write(filter.feed(chunk));
      }
      out.write(filter.flush());
      return out.toString();
    }

    test('hides the echoed suffix and the result line', () {
      final codes = <int>[];
      final shown = run('ab12', [
        ';echo __RC_ab12=\$?'.isEmpty
            ? ''
            : 'ls;echo __RC_ab12=\$?\r\nfile\r\n__RC_ab12=0\r\n\$ ',
      ], codes);
      expect(shown, 'ls\r\nfile\r\n\$ ');
      expect(codes, [0]);
    });

    test('works however the output is split', () {
      const whole = 'ls;echo __RC_ab12=\$?\r\nfile\r\n__RC_ab12=127\r\n\$ ';
      for (var size = 1; size <= whole.length; size++) {
        final codes = <int>[];
        final chunks = [
          for (var i = 0; i < whole.length; i += size)
            whole.substring(i, min(i + size, whole.length)),
        ];
        expect(
          run('ab12', chunks, codes),
          'ls\r\nfile\r\n\$ ',
          reason: 'chunk size $size',
        );
        expect(codes, [127], reason: 'chunk size $size');
      }
    });

    test('other text that looks similar is shown', () {
      final codes = <int>[];
      expect(
        run('ab12', ['echo __RC_zz99=1\r\n', '__RC_ab1\r\n'], codes),
        'echo __RC_zz99=1\r\n__RC_ab1\r\n',
      );
      expect(codes, isEmpty);
    });
  });

  group('runner', () {
    test('steps run in order and report their exit codes', () async {
      final shell = SimShell({'echo hi': ('hi', 0), 'false': ('', 1)});
      final runner = makeRunner(shell);
      final events = <String>[];

      final result = await runner.run(const [
        RunStep(command: 'echo hi'),
        RunStep(command: 'false'),
        RunStep(command: 'pwd'),
      ], onStep: (i, s) => events.add('$i:${s.name}'));

      expect(result.status, RunStatus.failed);
      expect(result.steps, [
        StepStatus.succeeded,
        StepStatus.failed,
        StepStatus.succeeded,
      ]);
      expect(result.exitCodes, {0: 0, 1: 1, 2: 0});
      expect(events, [
        '0:running',
        '0:succeeded',
        '1:running',
        '1:failed',
        '2:running',
        '2:succeeded',
      ]);
    });

    test('stop at first failure skips the rest', () async {
      final shell = SimShell({'false': ('', 2)});
      final result = await makeRunner(shell).run(const [
        RunStep(command: 'echo a'),
        RunStep(command: 'false'),
        RunStep(command: 'echo c'),
      ], stopOnFailure: true);

      expect(result.status, RunStatus.failed);
      expect(result.steps, [
        StepStatus.succeeded,
        StepStatus.failed,
        StepStatus.skipped,
      ]);
      expect(shell.written.where((w) => w.contains('echo c')), isEmpty);
    });

    test(
      'the marker is never in what is displayed, even split small',
      () async {
        final shell = SimShell({'ls': ('a b', 0)}, chunkSize: 3);
        final result = await makeRunner(shell)
            .run(const [RunStep(command: 'ls')]);

        expect(result.status, RunStatus.succeeded);
        expect(shell.display.toString(), 'ls\r\na b\r\n\$ ');
        expect(shell.display.toString(), isNot(contains('__RC_')));
      },
    );

    test('a step that never finishes times out', () async {
      final shell = SimShell({});
      final runner = SnippetRunner(write: (_) {}, random: Random(1));
      shell.runner = runner;

      final result = await runner.run(const [
        RunStep(command: 'sleep 100', timeout: Duration(milliseconds: 50)),
        RunStep(command: 'next'),
      ], stopOnFailure: true);

      expect(result.steps, [StepStatus.timedOut, StepStatus.skipped]);
      expect(result.status, RunStatus.failed);
    });

    test(
      'text appears: waits for the text, not the echo of the command',
      () async {
        late SnippetRunner runner;
        final sent = <String>[];
        runner = SnippetRunner(
          write: (text) {
            sent.add(text);
            // The shell echoes the command, which contains "ready" too.
            runner.feed('${text.trimRight()}\r\n');
          },
          random: Random(1),
        );
        final run = runner.run(const [
          RunStep(
            command: 'echo ready',
            wait: WaitRule.text('ready'),
            timeout: Duration(milliseconds: 200),
          ),
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        var done = false;
        unawaited(run.then((_) => done = true));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          done,
          isFalse,
          reason: 'the echo alone must not satisfy the wait',
        );

        runner.feed('server ready\r\n');
        final result = await run;
        expect(result.steps.single, StepStatus.succeeded);
      },
    );

    test('text that never appears times out', () async {
      final runner = SnippetRunner(write: (_) {}, random: Random(1));
      final result = await runner.run(const [
        RunStep(
          command: 'tail -f x',
          wait: WaitRule.text('never'),
          timeout: Duration(milliseconds: 40),
        ),
      ]);
      expect(result.steps.single, StepStatus.timedOut);
    });

    test('a fixed wait just waits', () async {
      final runner = SnippetRunner(write: (_) {}, random: Random(1));
      final watch = Stopwatch()..start();
      final result = await runner.run(const [
        RunStep(command: 'sleep 1', wait: WaitRule.seconds(1)),
      ]);
      expect(result.steps.single, StepStatus.succeeded);
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(900));
    });

    test('cancel abandons the step and skips the rest', () async {
      final runner = SnippetRunner(write: (_) {}, random: Random(1));
      final run = runner.run(const [
        RunStep(command: 'sleep 100'),
        RunStep(command: 'next'),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      runner.cancel();
      final result = await run;

      expect(result.status, RunStatus.cancelled);
      expect(result.steps, [StepStatus.skipped, StepStatus.skipped]);
    });
  });
}
