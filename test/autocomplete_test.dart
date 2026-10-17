import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/models/snippet.dart';
import 'package:ssh_app/services/autocomplete/completion_engine.dart';
import 'package:ssh_app/services/autocomplete/directory_lister.dart';
import 'package:ssh_app/services/autocomplete/history.dart';
import 'package:ssh_app/services/autocomplete/line_tracker.dart';
import 'package:ssh_app/services/autocomplete/shell_integration.dart';
import 'package:ssh_app/services/autocomplete/shell_marks.dart';

void main() {
  directoryListerTests();
  final now = DateTime.utc(2026, 10, 17, 12);

  group('OSC 133 and OSC 7', () {
    test('prompt marks and the exit code are reported', () {
      final events = <String>[];
      final marks = ShellMarks(
        onPromptStart: () => events.add('A'),
        onPromptEnd: () => events.add('B'),
        onCommandEnd: (code) => events.add('D$code'),
      );

      expect(marks.active, isFalse);
      expect(marks.handle('133', ['D', '127']), isTrue);
      expect(marks.handle('133', ['A']), isTrue);
      expect(marks.handle('133', ['B']), isTrue);
      expect(marks.handle('133', ['D']), isTrue);
      expect(marks.handle('133', ['A', 'k=v']), isTrue);

      expect(events, ['D127', 'A', 'B', 'Dnull', 'A']);
      expect(marks.active, isTrue);
    });

    test('the directory is decoded from a file URL', () {
      String? cwd;
      final marks = ShellMarks(onDirectory: (path) => cwd = path);

      marks.handle('7', ['file://myhost/home/ada/my%20project']);
      expect(cwd, '/home/ada/my project');

      // A ';' in the path split it into arguments.
      marks.handle('7', ['file://myhost/a', 'b']);
      expect(cwd, '/a;b');
    });

    test('other sequences are not ours', () {
      final marks = ShellMarks();
      expect(marks.handle('1337', ['x']), isFalse);
      expect(marks.handle('133', []), isFalse);
      expect(marks.handle('133', ['Z']), isFalse);
      expect(marks.handle('7', ['http://x/y']), isFalse);
      expect(marks.active, isFalse);
    });

    test('the install command carries the script and checks for it first', () {
      final command = shellIntegrationInstallCommand();
      expect(command, isNot(contains('\n')));
      expect(command, contains('grep -q $shellIntegrationMarker'));
      expect(command, contains('base64 -d >>'));
      expect(shellIntegrationScript, contains('133;B'));
      expect(shellIntegrationScript, contains(']7;file://'));
    });
  });

  group('fallback: tracking keys', () {
    test('typing, backspace and Enter', () {
      final tracker = InputLineTracker();
      expect(tracker.feed('ls -l'), isEmpty);
      expect(tracker.line, 'ls -l');

      tracker.feed('\x7f');
      expect(tracker.line, 'ls -');

      expect(tracker.feed('a\r'), ['ls -a']);
      expect(tracker.line, '');
    });

    test('Ctrl+C, Ctrl+U and Ctrl+W', () {
      final tracker = InputLineTracker()..feed('git commit');
      tracker.feed('\x17');
      expect(tracker.line, 'git ');
      tracker.feed('status');
      tracker.feed('\x03');
      expect(tracker.line, '');
      tracker.feed('abc\x15');
      expect(tracker.line, '');
    });

    test('arrows, history and Tab make the line unknown until Enter', () {
      final tracker = InputLineTracker()..feed('ec');
      tracker.feed('\x1b[A');
      expect(tracker.line, isNull);
      tracker.feed('ho');
      expect(tracker.line, isNull);

      expect(tracker.feed('\r'), [null]);
      expect(tracker.line, '');

      tracker.feed('cd /et\t');
      expect(tracker.line, isNull);
      tracker.feed('\x03');
      expect(tracker.line, '');
    });

    test('a paste with line breaks submits each line', () {
      final tracker = InputLineTracker();
      expect(tracker.feed('one\rtwo\nthree'), ['one', 'two']);
      expect(tracker.line, 'three');
    });

    test('an Alt key or a function key is skipped whole', () {
      final tracker = InputLineTracker()..feed('x');
      tracker.feed('\x1b[15~');
      tracker.feed('\x1bb');
      tracker.feed('\x03');
      tracker.feed('y');
      expect(tracker.line, 'y');
    });
  });

  group('history', () {
    test('commands that look sensitive or start with a space are not kept', () {
      for (final line in [
        ' ls',
        'mysql -u root --password=hunter2',
        'export API_KEY=abc',
        'curl -H "Authorization: Bearer x"',
        'echo token',
        'gpg --passphrase x',
        'aws configure set key=value',
        'cat secret.txt',
        '',
        '   ',
      ]) {
        expect(isRecordable(line), isFalse, reason: line);
      }
      for (final line in ['ls -la', 'git push origin main', 'docker ps']) {
        expect(isRecordable(line), isTrue, reason: line);
      }
    });

    test('counts repeats and remembers when', () async {
      var time = now;
      final history = CommandHistory(MemoryHistoryStore(), clock: () => time);

      expect(await history.record('a', 'ls -la'), isTrue);
      time = now.add(const Duration(hours: 2));
      await history.record('a', 'ls -la');
      expect(await history.record('a', ' hidden'), isFalse);
      await history.record('b', 'pwd');

      final entry = history.entries('a').single;
      expect(entry.count, 2);
      expect(entry.lastUsed, time);
      expect(history.entries('b').single.command, 'pwd');
    });

    test('keeps at most the limit, dropping the least recently used', () async {
      var time = now;
      final history = CommandHistory(
        MemoryHistoryStore(),
        limit: 3,
        clock: () => time,
      );
      for (final command in ['one', 'two', 'three']) {
        time = time.add(const Duration(minutes: 1));
        await history.record('a', command);
      }
      time = time.add(const Duration(minutes: 1));
      await history.record('a', 'one'); // refreshed
      time = time.add(const Duration(minutes: 1));
      await history.record('a', 'four');

      expect(history.entries('a').map((e) => e.command).toSet(), {
        'one',
        'three',
        'four',
      });
    });

    test('survives a restart and clears per host', () async {
      final store = MemoryHistoryStore();
      await CommandHistory(store).record('a', 'uptime');
      await CommandHistory(store).record('b', 'df');

      final reopened = CommandHistory(store);
      expect(reopened.entries('a').single.command, 'uptime');
      await reopened.clear('a');
      expect(reopened.entries('a'), isEmpty);
      expect(CommandHistory(store).entries('b'), isNotEmpty);
    });

    test('the default limit is 2000', () {
      expect(CommandHistory(MemoryHistoryStore()).limit, 2000);
    });
  });

  group('completion engine', () {
    CompletionEngine engine({
      List<HistoryEntry> history = const [],
      List<Snippet> snippets = const [],
      Map<String, List<String>> dirs = const {},
      List<String>? asked,
    }) {
      return CompletionEngine(
        history: () => history,
        snippets: () => snippets,
        clock: () => now,
        listDirectory: (dir) async {
          asked?.add(dir);
          return dirs[dir] ?? const [];
        },
      );
    }

    const pathsOnly = CompletionSources(
      history: false,
      snippets: false,
      common: false,
    );

    HistoryEntry entry(String command, int count, Duration ago) => HistoryEntry(
      command: command,
      count: count,
      lastUsed: now.subtract(ago),
    );

    test('nothing for an empty line or with every source off', () async {
      final e = engine();
      expect(await e.suggest(''), isEmpty);
      expect(await e.suggest('  '), isEmpty);
      expect(
        await e.suggest(
          'git',
          sources: const CompletionSources(
            paths: false,
            history: false,
            snippets: false,
            common: false,
          ),
        ),
        isEmpty,
      );
    });

    test(
      'history ranks by how often and how recently, with a meta line',
      () async {
        final e = engine(
          history: [
            entry('git status', 2, const Duration(days: 30)),
            entry('git pull --rebase', 14, const Duration(hours: 2)),
            entry('git push', 5, const Duration(hours: 1)),
            entry('docker ps', 99, const Duration(minutes: 1)),
          ],
        );

        final results = await e.suggest(
          'git p',
          sources: const CompletionSources(common: false),
        );

        expect(results.map((s) => s.label), ['git pull --rebase', 'git push']);
        expect(results.first.insert, 'ull --rebase');
        expect(results.first.meta, '14x, last 2h ago');
        expect(
          results.every((s) => s.source == SuggestionSource.history),
          isTrue,
        );
      },
    );

    test('sources are ranked: paths, history, snippets, common', () async {
      final e = engine(
        history: [entry('tail -n 50 app.log', 3, const Duration(hours: 1))],
        snippets: [
          Snippet.create(
            name: 'Follow syslog',
            steps: const [SnippetStep(command: 'tail -f /var/log/syslog')],
          ),
        ],
        dirs: {
          '/var/': ['log/', 'lib/', 'local.txt'],
        },
      );

      final results = await e.suggest('tail ');
      expect(results.map((s) => s.source), [
        SuggestionSource.history,
        SuggestionSource.snippet,
        SuggestionSource.common,
      ]);
      expect(results.map((s) => s.label), [
        'tail -n 50 app.log',
        'Follow syslog',
        'tail -f',
      ]);

      // With a path in progress, the folder listing leads.
      final withPath = await e.suggest('tail /var/l');
      expect(withPath.first.source, SuggestionSource.path);
      expect(withPath.map((s) => s.label), ['lib/', 'log/', 'local.txt']);
      expect(withPath.first.insert, 'ib/');
    });

    test(
      'paths: only for commands that take them, folders first, cd only folders',
      () async {
        final asked = <String>[];
        final e = engine(
          asked: asked,
          dirs: {
            '/home/ada/': [
              'bin/',
              'notes.txt',
              'Downloads/',
              '.ssh/',
              'my docs/',
            ],
          },
        );

        var results = await e.suggest(
          'ls ',
          cwd: '/home/ada',
          sources: pathsOnly,
        );
        expect(results.map((s) => s.label), [
          'bin/',
          'Downloads/',
          'my docs/',
          'notes.txt',
        ]);
        expect(results.map((s) => s.label), isNot(contains('.ssh/')));

        results = await e.suggest('cd ', cwd: '/home/ada', sources: pathsOnly);
        expect(results.map((s) => s.label), ['bin/', 'Downloads/', 'my docs/']);

        results = await e.suggest(
          'ls my',
          cwd: '/home/ada',
          sources: pathsOnly,
        );
        expect(results.single.insert, r' docs/'.replaceAll(' ', r'\ '));

        results = await e.suggest(
          'ls .s',
          cwd: '/home/ada',
          sources: pathsOnly,
        );
        expect(results.single.label, '.ssh/');

        // Not a path command, and a flag is not a path.
        asked.clear();
        expect(
          await e.suggest(
            'echo ',
            cwd: '/home/ada',
            sources: const CompletionSources(common: false),
          ),
          isEmpty,
        );
        expect(
          await e.suggest(
            'ls -',
            cwd: '/home/ada',
            sources: const CompletionSources(common: false),
          ),
          isEmpty,
        );
        expect(asked, isEmpty);
      },
    );

    test(
      'a relative path needs the directory; absolute and ~ do not',
      () async {
        final asked = <String>[];
        final e = engine(
          asked: asked,
          dirs: {
            '/etc/': ['hosts'],
            '~/': ['bin/'],
            '/home/ada/src/': ['main.dart'],
          },
        );
        const only = CompletionSources(
          history: false,
          snippets: false,
          common: false,
        );

        expect(await e.suggest('cat src/', sources: only), isEmpty);
        expect(asked, isEmpty, reason: 'unknown directory: do not guess');

        expect(
          (await e.suggest('cat /etc/h', sources: only)).single.label,
          'hosts',
        );
        expect((await e.suggest('cd ~/b', sources: only)).single.label, 'bin/');
        expect(
          (await e.suggest(
            'cat src/m',
            cwd: '/home/ada',
            sources: only,
          )).single.label,
          'main.dart',
        );
      },
    );

    test(
      'snippets match by first command, or by name which is replaced',
      () async {
        final e = engine(
          snippets: [
            Snippet.create(
              name: 'Attach',
              steps: const [SnippetStep(command: 'tmux new -A -s main')],
            ),
            Snippet.create(
              name: 'Needs input',
              steps: const [SnippetStep(command: r'echo ${X}')],
            ),
          ],
        );
        const only = CompletionSources(
          paths: false,
          history: false,
          common: false,
        );

        var results = await e.suggest('tmux n', sources: only);
        expect(results.single.label, 'Attach');
        expect(results.single.applyTo('tmux n'), 'tmux new -A -s main');

        results = await e.suggest('att', sources: only);
        expect(results.single.deleteCount, 3);
        expect(results.single.applyTo('att'), 'tmux new -A -s main');

        // A snippet that needs values cannot be typed in for the user.
        expect(await e.suggest('echo', sources: only), isEmpty);
      },
    );

    test(
      'a completion must extend what was typed, and is not offered twice',
      () async {
        final e = engine(
          history: [entry('docker ps', 1, const Duration(hours: 1))],
        );

        final results = await e.suggest('docker ps');
        expect(
          results.map((s) => s.applyTo('docker ps')),
          isNot(contains('docker ps')),
        );
        expect(
          results.map((s) => s.applyTo('docker ps')).toSet().length,
          results.length,
        );
        expect((await e.suggest('docker p')).first.label, 'docker ps');
        // History and the common list both have it: shown once.
        expect(
          (await e.suggest('docker p')).where((s) => s.label == 'docker ps'),
          hasLength(1),
        );
      },
    );

    test('word splitting honors escaped spaces', () {
      expect(CompletionEngine.splitToken(r'cat my\ fi').token, r'my\ fi');
      expect(CompletionEngine.splitToken('cat ').token, '');
      expect(CompletionEngine.splitToken('ls').before, '');
    });

    test('at most maxResults come back', () async {
      final e = engine(
        history: [
          for (var i = 0; i < 20; i++)
            entry('make t$i', i, const Duration(hours: 1)),
        ],
      );
      expect((await e.suggest('make')).length, 8);
    });
  });
}

void directoryListerTests() {
  group('remote directory lister', () {
    test('lists, caches for 30s and shares concurrent requests', () async {
      var now = DateTime.utc(2026, 1, 1);
      final commands = <String>[];
      final lister = RemoteDirectoryLister(
        clock: () => now,
        exec: (command) async {
          commands.add(command);
          return 'bin/\r\nnotes.txt\n\n';
        },
      );

      final both = await Future.wait([
        lister.list('/home/ada/'),
        lister.list('/home/ada/'),
      ]);
      expect(both.first, ['bin/', 'notes.txt']);
      expect(commands, hasLength(1));

      now = now.add(const Duration(seconds: 29));
      await lister.list('/home/ada/');
      expect(commands, hasLength(1));

      now = now.add(const Duration(seconds: 2));
      await lister.list('/home/ada/');
      expect(commands, hasLength(2));
    });

    test(
      'a failure or a hang gives nothing, and is not retried at once',
      () async {
        var now = DateTime.utc(2026, 1, 1);
        var calls = 0;
        final lister = RemoteDirectoryLister(
          clock: () => now,
          timeout: const Duration(milliseconds: 20),
          exec: (command) async {
            calls++;
            if (calls == 1) throw StateError('channel refused');
            await Completer<void>().future;
            return '';
          },
        );

        expect(await lister.list('/x/'), isEmpty);
        expect(await lister.list('/x/'), isEmpty);
        expect(calls, 1);

        now = now.add(const Duration(seconds: 6));
        expect(await lister.list('/x/'), isEmpty); // times out
        expect(calls, 2);
      },
    );

    test('the command quotes names and leaves ~ to the shell', () {
      expect(
        RemoteDirectoryLister.listCommand('/srv/my dir/', 500),
        "ls -1Ap -- '/srv/my dir/' 2>/dev/null | head -n 500",
      );
      expect(
        RemoteDirectoryLister.listCommand("/it's/", 10),
        r"ls -1Ap -- '/it'\''s/' 2>/dev/null | head -n 10",
      );
      expect(
        RemoteDirectoryLister.listCommand(r'/a/$(rm -rf ~)/', 10),
        r"ls -1Ap -- '/a/$(rm -rf ~)/' 2>/dev/null | head -n 10",
      );
      expect(
        RemoteDirectoryLister.listCommand('~/', 10),
        r'ls -1Ap -- "$HOME"/ 2>/dev/null | head -n 10',
      );
      expect(
        RemoteDirectoryLister.listCommand('~/my docs/', 10),
        r"""ls -1Ap -- "$HOME"/'my docs/' 2>/dev/null | head -n 10""",
      );
    });
  });
}
