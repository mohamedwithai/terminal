import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/services/snippets/multi_host_run.dart';
import 'package:ssh_app/services/snippets/snippet_runner.dart';

ServerConfig host(String id) => ServerConfig.create(
  id: id,
  label: 'Host $id',
  host: '$id.example.com',
  username: 'ada',
  authType: AuthType.password,
);

/// A fake shell: replies to each command from [script] and never talks
/// unless asked, so tests can hold a command open.
class FakeHostShell implements HostShell {
  FakeHostShell(this.script, {this.hangOn});

  final Map<String, (String, int)> script;
  final String? hangOn;
  final _out = StreamController<String>();
  final written = <String>[];
  var closed = false;

  @override
  Stream<String> get output => _out.stream;

  @override
  void write(String text) {
    written.add(text);
    final line = text.endsWith('\r')
        ? text.substring(0, text.length - 1)
        : text;
    final marker = RegExp(r';echo __RC_(\w+)=\$\?$').firstMatch(line);
    final command = marker == null ? line : line.substring(0, marker.start);
    if (command == hangOn) return;
    final (output, code) = script[command] ?? ('', 0);
    _out.add('$line\r\n');
    if (output.isNotEmpty) _out.add('$output\r\n');
    if (marker != null) _out.add('__RC_${marker.group(1)}=$code\r\n');
  }

  @override
  Future<void> close() async {
    closed = true;
    // A controller nobody listened to never finishes closing; don't wait.
    unawaited(_out.close());
  }
}

void main() {
  const steps = [RunStep(command: 'uptime'), RunStep(command: 'df -h')];

  test('runs on every host at once and reports each separately', () async {
    final shells = <String, FakeHostShell>{
      'a': FakeHostShell({'uptime': ('up 3 days', 0)}),
      'b': FakeHostShell({'df -h': ('', 1)}),
    };
    final run = MultiHostRun(
      servers: [host('a'), host('b'), host('c')],
      steps: steps,
      opener: (server) async {
        if (server.id == 'c') {
          throw const HostRunException('Host key not trusted yet.');
        }
        return shells[server.id]!;
      },
    );
    var changes = 0;
    run.changes.listen((_) => changes++);

    await run.start();
    await run.done;

    final a = run.hosts[0];
    final b = run.hosts[1];
    final c = run.hosts[2];
    expect(a.status, HostRunStatus.succeeded);
    expect(a.output, contains('up 3 days'));
    expect(a.output, isNot(contains('__RC_')));
    expect(b.status, HostRunStatus.failed);
    expect(b.steps, [StepStatus.succeeded, StepStatus.failed]);
    expect(c.status, HostRunStatus.unreachable);
    expect(c.message, 'Host key not trusted yet.');
    expect(run.isDone, isTrue);
    expect(run.succeeded, isFalse);
    expect(run.failedCount, 2);
    expect(changes, greaterThan(0));
    expect(shells['a']!.closed, isTrue);
    expect(shells['b']!.closed, isTrue);
  });

  test('hosts do not wait for each other', () async {
    final slow = Completer<void>();
    final fast = FakeHostShell({});
    final run = MultiHostRun(
      servers: [host('slow'), host('fast')],
      steps: const [RunStep(command: 'ls')],
      opener: (server) async {
        if (server.id == 'slow') await slow.future;
        return server.id == 'fast' ? fast : FakeHostShell({});
      },
    );
    unawaited(run.start());
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(run.hosts[1].status, HostRunStatus.succeeded);
    expect(run.hosts[0].status, HostRunStatus.connecting);

    slow.complete();
    await run.done;
    expect(run.succeeded, isTrue);
  });

  test('stop all abandons running hosts and closes their shells', () async {
    final shells = {
      'a': FakeHostShell({}, hangOn: 'uptime'),
      'b': FakeHostShell({}, hangOn: 'uptime'),
    };
    final run = MultiHostRun(
      servers: [host('a'), host('b')],
      steps: steps,
      opener: (server) async => shells[server.id]!,
    );
    unawaited(run.start());
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(run.hosts.every((h) => h.status == HostRunStatus.running), isTrue);

    run.stopAll();
    await run.done;

    expect(run.hosts.every((h) => h.status == HostRunStatus.cancelled), isTrue);
    expect(shells.values.every((s) => s.closed), isTrue);
    // The second step was never sent.
    expect(shells['a']!.written.any((w) => w.contains('df -h')), isFalse);
  });

  test(
    'stopping before a host connects cancels it and closes its shell',
    () async {
      final gate = Completer<void>();
      final shell = FakeHostShell({});
      final run = MultiHostRun(
        servers: [host('a')],
        steps: steps,
        opener: (server) async {
          await gate.future;
          return shell;
        },
      );
      unawaited(run.start());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      run.stopAll();
      gate.complete();
      await run.done;

      expect(run.hosts.single.status, HostRunStatus.cancelled);
      expect(shell.closed, isTrue);
      expect(shell.written, isEmpty);
    },
  );

  test('an unexpected error from the opener is a plain message', () async {
    final run = MultiHostRun(
      servers: [host('a')],
      steps: steps,
      opener: (server) async => throw StateError('secret detail'),
    );
    await run.start();

    expect(run.hosts.single.status, HostRunStatus.unreachable);
    expect(run.hosts.single.message, isNot(contains('secret detail')));
  });

  test('stop at first failure applies on every host', () async {
    final shell = FakeHostShell({'uptime': ('', 3)});
    final run = MultiHostRun(
      servers: [host('a')],
      steps: steps,
      stopOnFailure: true,
      opener: (server) async => shell,
    );
    await run.start();

    expect(run.hosts.single.steps, [StepStatus.failed, StepStatus.skipped]);
  });
}
