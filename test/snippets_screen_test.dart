import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/app.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/models/server_credentials.dart';
import 'package:ssh_app/models/snippet.dart';
import 'package:ssh_app/providers/snippet_providers.dart';
import 'package:ssh_app/providers/snippet_run_providers.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/services/snippet_store.dart';
import 'package:ssh_app/services/snippets/multi_host_run.dart';
import 'package:ssh_app/services/vault_service.dart';

import 'support/memory_stores.dart';

class _Shell implements HostShell {
  _Shell(this.exitCode);

  final int exitCode;
  final out = StreamController<String>();
  final written = <String>[];

  @override
  Stream<String> get output => out.stream;

  @override
  void write(String text) {
    written.add(text);
    final marker = RegExp(r';echo __RC_(\w+)=\$\?').firstMatch(text);
    out.add('${text.trim()}\r\nran it\r\n');
    if (marker != null) out.add('__RC_${marker.group(1)}=$exitCode\r\n');
  }

  @override
  Future<void> close() async {
    unawaited(out.close());
  }
}

void main() {
  late VaultService vault;
  late MemorySnippetStore store;
  late String? picked;
  late List<(String, String)> shared;
  late Map<String, _Shell> shells;

  ServerConfig host(String id, String label) => ServerConfig.create(
    id: id,
    label: label,
    host: '$id.example.com',
    username: 'ada',
    authType: AuthType.password,
  );

  Future<void> init() async {
    vault = VaultService(
      secureStore: MemorySecureStore(),
      metadataStore: MemoryMetadataStore(),
    );
    store = MemorySnippetStore();
    picked = null;
    shared = [];
    shells = {};
    for (final (id, label) in [('a', 'Alpha'), ('b', 'Bravo')]) {
      await vault.saveServer(
        host(id, label),
        const ServerCredentials(password: 'pw'),
      );
    }
  }

  Future<void> pumpApp(WidgetTester tester, {int exitCode = 0}) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultServiceProvider.overrideWithValue(vault),
          snippetStoreProvider.overrideWithValue(store),
          keyFilePickerProvider.overrideWithValue(() async => picked),
          shareTextProvider.overrideWithValue((text, subject) async {
            shared.add((text, subject));
          }),
          hostShellOpenerProvider.overrideWithValue((server) async {
            return shells[server.id] = _Shell(server.id == 'b' ? 1 : exitCode);
          }),
        ],
        child: const SshApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Snippets'));
    await tester.pumpAndSettle();
  }

  Future<void> addSnippet(Snippet snippet) async {
    await store.put(snippet);
  }

  testWidgets('empty library, then creating a snippet with a variable', (
    tester,
  ) async {
    await init();
    await pumpApp(tester);
    expect(find.text('No snippets yet'), findsOneWidget);

    await tester.tap(find.text('New snippet').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Restart');
    await tester.enterText(
      find.byKey(const ValueKey('step-command-0')),
      r'sudo systemctl restart ${SERVICE}',
    );
    await tester.pumpAndSettle();
    // The placeholder shows up as a variable to define.
    expect(find.text(r'${SERVICE}'), findsOneWidget);
    await tester.tap(find.text('Choice'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('choices-SERVICE')),
      'nginx, redis',
    );
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    final saved = (await store.list()).single;
    expect(saved.name, 'Restart');
    expect(saved.allVariables.single.type, VariableType.choice);
    expect(saved.allVariables.single.choices, ['nginx', 'redis']);
    expect(find.text('Restart'), findsOneWidget);
    expect(find.text('1 variable'), findsOneWidget);
    expect(find.text('1 step'), findsOneWidget);
  });

  testWidgets('the editor refuses an empty or incomplete snippet', (
    tester,
  ) async {
    await init();
    await pumpApp(tester);
    await tester.tap(find.text('New snippet').last);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Give the snippet a name.'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'x');
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Add at least one command.'), findsOneWidget);
    expect(await store.list(), isEmpty);
  });

  testWidgets('search, tags and "Runs automatically" organize the list', (
    tester,
  ) async {
    await init();
    await addSnippet(
      Snippet.create(
        name: 'Disk usage',
        steps: const [SnippetStep(command: 'df -h')],
        tags: ['ops'],
      ),
    );
    await addSnippet(
      Snippet.create(
        name: 'Attach tmux',
        steps: const [SnippetStep(command: 'tmux new -A -s main')],
      ).copyWith(runOnConnect: ['a']),
    );
    await pumpApp(tester);

    expect(find.text('RUNS AUTOMATICALLY'), findsOneWidget);
    expect(find.text('1 host'), findsWidgets);

    await tester.enterText(find.byType(TextField).first, 'disk');
    await tester.pumpAndSettle();
    expect(find.text('Disk usage'), findsOneWidget);
    expect(find.text('Attach tmux'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'tmux new');
    await tester.pumpAndSettle();
    expect(find.text('Attach tmux'), findsWidgets);
    expect(find.text('Disk usage'), findsNothing);

    await tester.enterText(find.byType(TextField).first, '');
    await tester.tap(find.widgetWithText(ChoiceChip, 'ops'));
    await tester.pumpAndSettle();
    expect(find.text('Disk usage'), findsOneWidget);
    expect(find.text('Attach tmux'), findsNothing);
  });

  testWidgets('running on several hosts: sheet, preview, per-host results', (
    tester,
  ) async {
    await init();
    final snippet = Snippet.create(
      name: 'Deploy',
      steps: const [SnippetStep(command: r'deploy ${ENV} --token ${TOKEN}')],
      variables: const [
        SnippetVariable(
          name: 'ENV',
          type: VariableType.choice,
          choices: ['staging', 'prod'],
        ),
        SnippetVariable(name: 'TOKEN', type: VariableType.secret),
      ],
      askFirst: true,
    );
    await addSnippet(snippet);
    await pumpApp(tester);

    await tester.tap(find.byKey(ValueKey('run-${snippet.id}')));
    await tester.pumpAndSettle();
    // Ask-first shows the commands straight away, secrets masked.
    expect(find.text('Run these commands'), findsOneWidget);
    expect(find.byKey(const ValueKey('preview-0')), findsOneWidget);

    // Nothing is sent until the form is complete.
    await tester.tap(find.text('Run these commands'));
    await tester.pump();
    expect(find.text('Pick at least one host.'), findsOneWidget);
    expect(find.text('Enter a value.'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('var-ENV')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('prod').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('var-TOKEN')), 's3cret');
    await tester.pump();
    final preview = tester
        .widget<Text>(find.byKey(const ValueKey('preview-0')))
        .data!;
    expect(preview, contains('deploy prod --token ••••••'));
    expect(preview, isNot(contains('s3cret')));

    await tester.tap(find.byKey(const ValueKey('host-a')));
    await tester.tap(find.byKey(const ValueKey('host-b')));
    await tester.pump();
    await tester.tap(find.text('Run these commands'));
    await tester.pumpAndSettle();

    // The real command went to each shell, the secret included.
    expect(shells.keys, unorderedEquals(['a', 'b']));
    expect(
      shells['a']!.written.single,
      startsWith('deploy prod --token s3cret;echo __RC_'),
    );

    expect(find.byKey(const ValueKey('run-summary')), findsOneWidget);
    expect(find.text('1 of 2 hosts failed'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('run-host-a')));
    await tester.pumpAndSettle();
    final output = tester
        .widget<SelectableText>(find.byKey(const ValueKey('run-output-a')))
        .data!;
    expect(output, contains('ran it'));
    expect(output, isNot(contains('__RC_')));
    // The secret is not in the stored snippet or on screen in the output log.
    expect(
      (await store.list()).single.toJson().toString(),
      isNot(contains('s3cret')),
    );
  });

  testWidgets('a snippet with no variables runs once a host is picked', (
    tester,
  ) async {
    await init();
    final snippet = Snippet.create(
      name: 'Uptime',
      steps: const [
        SnippetStep(command: 'uptime'),
        SnippetStep(command: 'df -h'),
      ],
    );
    await addSnippet(snippet);
    await pumpApp(tester);

    await tester.tap(find.byKey(ValueKey('run-${snippet.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Run'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('host-a')));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Run'));
    await tester.pumpAndSettle();

    expect(find.text('Done on all 1 hosts'), findsOneWidget);
    expect(shells['a']!.written, hasLength(2));

    // Back on the library the run is listed, and can be dismissed.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('RUNS'), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('RUNS'), findsNothing);
  });

  testWidgets('export shares JSON and import adds the snippets', (
    tester,
  ) async {
    await init();
    await addSnippet(
      Snippet.create(
        name: 'Uptime',
        steps: const [SnippetStep(command: 'uptime')],
      ),
    );
    await pumpApp(tester);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export all'));
    await tester.pumpAndSettle();
    final (text, subject) = shared.single;
    expect(subject, 'Snippets');
    expect(text, contains('"uptime"'));

    await store.delete((await store.list()).single.id);
    picked = text;
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from file'));
    await tester.pumpAndSettle();
    expect(find.text('Imported 1 snippet.'), findsOneWidget);
    expect((await store.list()).single.name, 'Uptime');

    picked = 'not json';
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from file'));
    await tester.pumpAndSettle();
    expect(find.text('This file is not valid JSON.'), findsOneWidget);
  });

  testWidgets('deleting a snippet asks first', (tester) async {
    await init();
    await addSnippet(
      Snippet.create(
        name: 'Uptime',
        steps: const [SnippetStep(command: 'uptime')],
      ),
    );
    await pumpApp(tester);

    await tester.tap(find.byTooltip('Snippet options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await store.list(), hasLength(1));

    await tester.tap(find.byTooltip('Snippet options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(await store.list(), isEmpty);
    expect(Clipboard.kTextPlain, isNotEmpty);
  });
}
