import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_app/models/auth_type.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/providers/ssh_providers.dart';
import 'package:ssh_app/screens/terminal_screen.dart';
import 'package:ssh_app/services/ssh/host_key_verifier.dart';
import 'package:ssh_app/services/ssh/ssh_connection_service.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';

void main() {
  final server = ServerConfig.create(
    id: 'term-1',
    label: 'Build box',
    host: 'example.com',
    username: 'ada',
    authType: AuthType.password,
    now: DateTime.utc(2026, 5, 1),
  );

  testWidgets('CTRL is one-shot until a second tap locks it', (tester) async {
    await tester.pumpWidget(_terminalApp(server));
    await tester.pump();

    await tester.tap(find.text('CTRL'));
    await tester.pump();
    expect(find.byTooltip('CTRL, next key'), findsOneWidget);
    expect(find.byIcon(Icons.lock), findsNothing);

    await tester.tap(find.text('ESC'));
    await tester.pump();
    expect(find.byTooltip('CTRL'), findsOneWidget);

    await tester.tap(find.text('CTRL'));
    await tester.pump();
    await tester.tap(find.text('CTRL'));
    await tester.pump();
    expect(find.byTooltip('CTRL, locked'), findsOneWidget);
    expect(find.byIcon(Icons.lock), findsOneWidget);

    await tester.tap(find.text('ESC'));
    await tester.pump();
    expect(find.byTooltip('CTRL, locked'), findsOneWidget);

    await tester.tap(find.text('CTRL'));
    await tester.pump();
    expect(find.byTooltip('CTRL'), findsOneWidget);
    expect(find.byIcon(Icons.lock), findsNothing);
  });

  testWidgets('back asks before disconnecting', (tester) async {
    final disconnects = <int>[0];
    await tester.pumpWidget(
      _terminalApp(server, disconnects: disconnects, pushed: true),
    );
    await tester.tap(find.text('Open terminal'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.text('Disconnect?'), findsOneWidget);
    expect(disconnects.single, 0);

    await tester.tap(find.text('Stay'));
    await tester.pumpAndSettle();
    expect(find.text('Disconnect?'), findsNothing);
    expect(find.byType(TerminalScreen), findsOneWidget);
    expect(disconnects.single, 0);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Disconnect'));
    await tester.pumpAndSettle();

    expect(disconnects.single, 1);
    expect(find.text('Open terminal'), findsOneWidget);
    expect(find.byType(TerminalScreen), findsNothing);
  });
}

Widget _terminalApp(
  ServerConfig server, {
  List<int>? disconnects,
  bool pushed = false,
}) {
  final terminal = TerminalScreen(server: server, sessionId: 'session-1');
  return ProviderScope(
    overrides: [
      sshConnectionServiceProvider.overrideWithValue(
        SSHConnectionService(
          hostKeyVerifier: HostKeyVerifier(
            findKnownHost: (host, port) async => null,
            saveKnownHost: (host) async {},
          ),
        ),
      ),
      sshSessionStateProvider.overrideWith(
        (ref, args) => Stream.value(const SSHConnectionState.disconnected()),
      ),
      sshSessionControllerProvider.overrideWith((ref, args) {
        return _CountingController(
          ref: ref,
          sessionId: args.sessionId,
          server: args.server,
          disconnects: disconnects,
        );
      }),
    ],
    child: MaterialApp(
      home: pushed
          ? Builder(
              builder: (context) {
                return Scaffold(
                  body: TextButton(
                    onPressed: () {
                      Navigator.of(
                        context,
                      ).push(MaterialPageRoute<void>(builder: (_) => terminal));
                    },
                    child: const Text('Open terminal'),
                  ),
                );
              },
            )
          : terminal,
    ),
  );
}

class _CountingController extends SSHSessionController {
  _CountingController({
    required super.ref,
    required super.sessionId,
    required super.server,
    this.disconnects,
  });

  final List<int>? disconnects;

  @override
  Future<void> disconnect() async {
    if (disconnects != null) {
      disconnects![0] += 1;
    }
  }
}
