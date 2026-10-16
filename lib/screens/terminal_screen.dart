import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/providers/ssh_providers.dart';
import 'package:ssh_app/screens/pty_resize.dart';
import 'package:ssh_app/screens/terminal_input.dart';
import 'package:ssh_app/screens/terminal_keyboard_bar.dart';
import 'package:ssh_app/screens/terminal_paste.dart';
import 'package:ssh_app/screens/terminal_selection.dart';
import 'package:ssh_app/services/ssh/ssh_connection_session.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';
import 'package:xterm/xterm.dart';

/// Written before the first output of the shell that replaces a lost one.
const reconnectedBanner = '--- reconnected, new shell ---';

/// Turns off what the lost shell's program may have switched on: the
/// alternate screen, a hidden cursor, mouse reporting, bracketed paste,
/// application cursor and keypad keys, and colors.
const _resetModes =
    '\x1b[?1049l\x1b[?25h\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l'
    '\x1b[?2004l\x1b[?1l\x1b>\x1b[0m';

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
  final _modifiers = TerminalModifiers();
  late final ModifierTerminal _terminal = ModifierTerminal(
    modifiers: _modifiers,
    maxLines: 10000,
  );
  final _terminalController = TerminalController();
  final _scrollController = ScrollController();
  final _terminalViewKey = GlobalKey<TerminalViewState>();
  late final _ptySize = PtyResizeDebouncer(send: _sendPtySize);
  final FocusNode _focusNode = FocusNode();

  SSHSession? _shell;
  StreamSubscription<String>? _outputSub;
  var _fontSize = 14.0;
  var _pinchBase = 14.0;
  var _pinchStart = 0.0;
  final Map<int, Offset> _pointers = {};
  var _opening = false;
  var _confirmingLeave = false;

  /// The connection dropped; the next shell is announced as a new one.
  var _connectionLost = false;

  /// The shell ended on its own (the user typed `exit`), so no new one is
  /// opened.
  var _shellExited = false;

  ({String sessionId, ServerConfig server}) get _args =>
      (sessionId: widget.sessionId, server: widget.server);

  SSHConnectionSession? get _session =>
      ref.read(sshConnectionServiceProvider).getSession(widget.sessionId);

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = _sendToShell;
    _terminal.onResize = _onTerminalResize;
    _modifiers.addListener(_onModifiersChanged);
  }

  @override
  void dispose() {
    _ptySize.dispose();
    _modifiers.removeListener(_onModifiersChanged);
    _modifiers.dispose();
    _outputSub?.cancel();
    _shell?.close();
    _terminalController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onModifiersChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _sendToShell(String data) {
    _session?.writeShell(utf8.encode(data));
  }

  /// Called by xterm during layout whenever the view's size in cells changes:
  /// the soft keyboard showing or hiding, rotation, or a pinch-zoom.
  void _onTerminalResize(int columns, int rows, int cellWidth, int cellHeight) {
    // xterm reports the size of one cell; the PTY wants the whole window's.
    _ptySize.resize((
      columns: columns,
      rows: rows,
      pixelWidth: columns * cellWidth,
      pixelHeight: rows * cellHeight,
    ));
  }

  void _sendPtySize(PtySize size) {
    _session?.resizeShell(
      size.columns,
      size.rows,
      size.pixelWidth,
      size.pixelHeight,
    );
  }

  void _onConnectionState(SSHConnectionState? state) {
    switch (state?.status) {
      case SSHConnectionStatus.connected:
        _ensureShell();
      case SSHConnectionStatus.reconnecting when !_connectionLost:
        _connectionLost = true;
        // The old shell went with the connection.
        _outputSub?.cancel();
        _outputSub = null;
        _shell = null;
      default:
        break;
    }
  }

  Future<void> _ensureShell() async {
    if (_opening || _shell != null || _shellExited) {
      return;
    }
    final session = _session;
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
      // The view may have changed size while the shell was opening.
      _ptySize.opened(columns, rows);
      if (_connectionLost) {
        _connectionLost = false;
        _terminal.write('$_resetModes\r\n$reconnectedBanner\r\n');
      }
      _outputSub = shell.stdout
          .map<List<int>>((chunk) => chunk)
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_terminal.write);
      unawaited(shell.done.then((_) => _onShellDone(shell)));
    } catch (error) {
      if (mounted) {
        _terminal.write('\r\nCould not open a shell: $error\r\n');
      }
    } finally {
      _opening = false;
    }
  }

  void _onShellDone(SSHSession shell) {
    if (!mounted || !identical(_shell, shell)) {
      return;
    }
    _shell = null;
    final client = _session?.client;
    if (client == null || client.isClosed) {
      // The connection dropped; a reconnect brings a new shell.
      return;
    }
    _shellExited = true;
    _terminal.write('\r\n[session closed]\r\n');
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
    _terminal.keyInput(key);
    _focusNode.requestFocus();
  }

  void _sendText(String text) {
    _terminal.textInput(text);
    _focusNode.requestFocus();
  }

  /// Pastes the clipboard, from the keyboard bar or the selection toolbar.
  ///
  /// Text with a line break is shown first and only pasted once confirmed,
  /// since each line break can run a command. [Terminal.paste] wraps the text
  /// in bracketed paste markers when the program turned that mode on.
  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (!mounted || text == null || text.isEmpty) {
      return;
    }
    if (pasteNeedsConfirmation(text)) {
      final confirmed = await confirmPaste(
        context,
        text,
        bracketed: _terminal.bracketedPasteMode,
      );
      if (!mounted || !confirmed) {
        return;
      }
    }
    _terminal.paste(preparePaste(text));
    if (_scrollController.hasClients) {
      final position = _scrollController.position;
      position.jumpTo(position.maxScrollExtent);
    }
    _focusNode.requestFocus();
  }

  /// Applies an armed on-screen modifier to a character typed on a hardware
  /// keyboard, before TerminalView turns the key into a [TerminalKey].
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !_modifiers.isArmed) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      // TerminalView combines the held keys with the armed ones.
      return KeyEventResult.ignored;
    }
    final character = event.character;
    if (character == null ||
        character.isEmpty ||
        character.codeUnitAt(0) < 0x20 ||
        character == '\x7f') {
      return KeyEventResult.ignored;
    }
    _terminal.textInput(character);
    return KeyEventResult.handled;
  }

  Future<void> _confirmLeave() async {
    if (_confirmingLeave || !mounted) {
      return;
    }
    _confirmingLeave = true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Disconnect?'),
          content: Text(
            'Disconnect from ${widget.server.label} and close this terminal?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Stay'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Disconnect'),
            ),
          ],
        );
      },
    );
    if (!mounted) {
      return;
    }
    if (leave != true) {
      _confirmingLeave = false;
      return;
    }
    await ref.read(sshSessionControllerProvider(_args)).disconnect();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  static String _describe(SSHConnectionState state) {
    return switch (state.status) {
      SSHConnectionStatus.reconnecting when state.waitingFor != null =>
        'Connection lost. Waiting for ${state.waitingFor} to reconnect.',
      SSHConnectionStatus.reconnecting =>
        'Connection lost. Reconnecting (attempt ${state.reconnectAttempt} of '
            '${state.maxReconnectAttempts})...',
      SSHConnectionStatus.disconnected => 'Disconnected.',
      _ => state.errorMessage ?? state.toString(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(sshSessionStateProvider(_args));
    final state = connection.asData?.value;

    ref.listen(sshSessionStateProvider(_args), (previous, next) {
      _onConnectionState(next.asData?.value);
    });

    final connected = state?.isConnected ?? false;
    if (connected && _shell == null && !_opening && !_shellExited) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureShell());
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          return;
        }
        unawaited(_confirmLeave());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
          title: Text(widget.server.label),
          actions: [
            IconButton(
              tooltip: 'Disconnect',
              onPressed: () => unawaited(_confirmLeave()),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Text(
                    _describe(state),
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
                child: TerminalSelectionOverlay(
                  terminal: _terminal,
                  controller: _terminalController,
                  scrollController: _scrollController,
                  terminalViewKey: _terminalViewKey,
                  onPaste: _pasteClipboard,
                  // TerminalView pads itself by MediaQuery.padding; the
                  // keyboard bar below already keeps clear of the system
                  // navigation bar, so the terminal can use every row.
                  child: MediaQuery.removePadding(
                    context: context,
                    removeBottom: true,
                    child: TerminalView(
                      _terminal,
                      key: _terminalViewKey,
                      controller: _terminalController,
                      scrollController: _scrollController,
                      focusNode: _focusNode,
                      autofocus: true,
                      deleteDetection: true,
                      textStyle: TerminalStyle(fontSize: _fontSize),
                      keyboardType: TextInputType.text,
                      onKeyEvent: _onKeyEvent,
                    ),
                  ),
                ),
              ),
            ),
            TerminalKeyboardBar(
              ctrl: _modifiers.ctrl,
              alt: _modifiers.alt,
              onToggleCtrl: _modifiers.toggleCtrl,
              onToggleAlt: _modifiers.toggleAlt,
              onKey: _sendKey,
              onText: _sendText,
              onPaste: () => unawaited(_pasteClipboard()),
            ),
          ],
        ),
      ),
    );
  }
}
