import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/providers/ssh_providers.dart';
import 'package:ssh_app/screens/terminal_keyboard_bar.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';
import 'package:xterm/xterm.dart';

/// Full-screen terminal bound to an already opened SSH session.
class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({
    super.key,
    required this.server,
    required this.sessionId,
  });

  final ServerConfig server;
  final String sessionId;

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  final Terminal _terminal = Terminal(maxLines: 10000);
  final FocusNode _focusNode = FocusNode();

  SSHSession? _shell;
  StreamSubscription<String>? _outputSub;
  var _fontSize = 14.0;
  var _pinchBase = 14.0;
  var _pinchStart = 0.0;
  final Map<int, Offset> _pointers = {};
  var _ctrl = false;
  var _alt = false;
  var _opening = false;

  ({String sessionId, ServerConfig server}) get _args =>
      (sessionId: widget.sessionId, server: widget.server);

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = _sendToShell;
    _terminal.onResize = _resizeShell;
  }

  @override
  void dispose() {
    _outputSub?.cancel();
    _shell?.close();
    _focusNode.dispose();
    super.dispose();
  }

  void _sendToShell(String data) {
    ref.read(sshConnectionServiceProvider).getSession(widget.sessionId)?.writeShell(
          utf8.encode(data),
        );
  }

  void _resizeShell(int columns, int rows, int pixelWidth, int pixelHeight) {
    ref.read(sshConnectionServiceProvider).getSession(widget.sessionId)?.resizeShell(
          columns,
          rows,
          pixelWidth,
          pixelHeight,
        );
  }

  Future<void> _ensureShell() async {
    if (_opening || _shell != null) {
      return;
    }
    final session = ref.read(sshConnectionServiceProvider).getSession(widget.sessionId);
    if (session == null || !session.isConnected) {
      return;
    }
    _opening = true;
    try {
      final columns = _terminal.viewWidth > 0 ? _terminal.viewWidth : 80;
      final rows = _terminal.viewHeight > 0 ? _terminal.viewHeight : 24;
      final shell = await session.openShell(columns: columns, rows: rows);
      if (!mounted) {
        shell.close();
        return;
      }
      await _outputSub?.cancel();
      _shell = shell;
      _outputSub = shell.stdout
          .map<List<int>>((chunk) => chunk)
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_terminal.write);
      unawaited(shell.done.then((_) {
        if (!mounted || !identical(_shell, shell)) {
          return;
        }
        _shell = null;
        _terminal.write('\r\n[session closed]\r\n');
      }));
    } catch (error) {
      if (mounted) {
        _terminal.write('\r\nCould not open a shell: $error\r\n');
      }
    } finally {
      _opening = false;
    }
  }

  void _trackPointer(PointerEvent event) {
    _pointers[event.pointer] = event.position;
  }

  void _endPointer(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length < 2) {
      _pinchStart = 0;
    }
  }

  double? get _pointerSpan {
    if (_pointers.length < 2) {
      return null;
    }
    final points = _pointers.values.toList();
    return (points[0] - points[1]).distance;
  }

  void _onPointerDown(PointerDownEvent event) {
    _trackPointer(event);
    final span = _pointerSpan;
    if (span != null && span > 0) {
      _pinchBase = _fontSize;
      _pinchStart = span;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    _trackPointer(event);
    final span = _pointerSpan;
    if (span == null || _pinchStart <= 0) {
      return;
    }
    setState(() {
      _fontSize = (_pinchBase * span / _pinchStart).clamp(8, 32);
    });
  }

  void _sendKey(TerminalKey key) {
    _terminal.keyInput(key, ctrl: _ctrl, alt: _alt);
    _focusNode.requestFocus();
  }

  void _sendText(String text) {
    if (_ctrl || _alt) {
      for (final code in text.codeUnits) {
        final handled = _terminal.charInput(code, ctrl: _ctrl, alt: _alt);
        if (!handled) {
          _terminal.textInput(text);
          break;
        }
      }
    } else {
      _terminal.textInput(text);
    }
    _focusNode.requestFocus();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || (!_ctrl && !_alt)) {
      return KeyEventResult.ignored;
    }
    final character = event.character;
    if (character == null || character.isEmpty) {
      return KeyEventResult.ignored;
    }
    final handled = _terminal.charInput(
      character.codeUnitAt(0),
      ctrl: _ctrl,
      alt: _alt,
    );
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(sshSessionStateProvider(_args));
    final state = connection.asData?.value;

    ref.listen(sshSessionStateProvider(_args), (previous, next) {
      final status = next.asData?.value.status;
      if (status == SSHConnectionStatus.connected) {
        _ensureShell();
      }
    });

    final connected = state?.isConnected ?? false;
    if (connected && _shell == null && !_opening) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureShell());
    }

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: Text(widget.server.label),
        actions: [
          IconButton(
            tooltip: 'Disconnect',
            onPressed: () async {
              await ref.read(sshSessionControllerProvider(_args)).disconnect();
              if (context.mounted) {
                Navigator.of(context).pop();
              }
            },
            icon: const Icon(Icons.power_settings_new),
          ),
        ],
      ),
      body: Column(
        children: [
          if (state != null && !connected)
            Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  state.errorMessage ?? state.toString(),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ),
          Expanded(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _endPointer,
              onPointerCancel: _endPointer,
              child: TerminalView(
                _terminal,
                focusNode: _focusNode,
                autofocus: true,
                deleteDetection: true,
                textStyle: TerminalStyle(fontSize: _fontSize),
                keyboardType: TextInputType.text,
                onKeyEvent: _onKeyEvent,
              ),
            ),
          ),
          TerminalKeyboardBar(
            ctrl: _ctrl,
            alt: _alt,
            onToggleCtrl: () => setState(() => _ctrl = !_ctrl),
            onToggleAlt: () => setState(() => _alt = !_alt),
            onKey: _sendKey,
            onText: _sendText,
          ),
        ],
      ),
    );
  }
}
