import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:ssh_app/providers/app_lock_providers.dart';
import 'package:ssh_app/providers/autocomplete_providers.dart';
import 'package:ssh_app/providers/preferences_providers.dart';
import 'package:ssh_app/providers/session_tabs_providers.dart';
import 'package:ssh_app/providers/snippet_providers.dart';
import 'package:ssh_app/providers/ssh_providers.dart';
import 'package:ssh_app/providers/vault_providers.dart';
import 'package:ssh_app/screens/pty_resize.dart';
import 'package:ssh_app/models/snippet.dart';
import 'package:ssh_app/screens/server_form_screen.dart';
import 'package:ssh_app/screens/snippets/run_sheet.dart';
import 'package:ssh_app/screens/snippets/snippet_picker_sheet.dart';
import 'package:ssh_app/services/autocomplete/completion_engine.dart';
import 'package:ssh_app/services/autocomplete/directory_lister.dart';
import 'package:ssh_app/services/autocomplete/shell_integration.dart';
import 'package:ssh_app/services/snippets/snippet_runner.dart';
import 'package:ssh_app/screens/settings_screen.dart';
import 'package:ssh_app/screens/terminal/autocomplete_controller.dart';
import 'package:ssh_app/screens/terminal/connection_card.dart';
import 'package:ssh_app/screens/terminal/connection_log_view.dart';
import 'package:ssh_app/screens/terminal/host_key_sheet.dart';
import 'package:ssh_app/screens/terminal/session_tab_bar.dart';
import 'package:ssh_app/screens/terminal/suggestion_panel.dart';
import 'package:ssh_app/screens/terminal_input.dart';
import 'package:ssh_app/screens/terminal_keyboard_bar.dart';
import 'package:ssh_app/screens/terminal_paste.dart';
import 'package:ssh_app/screens/terminal_selection.dart';
import 'package:ssh_app/screens/widgets/host_avatar.dart';
import 'package:ssh_app/services/ssh/ssh_connection_session.dart';
import 'package:ssh_app/services/ssh/ssh_connection_state.dart';
import 'package:ssh_app/services/ssh/ssh_errors.dart';
import 'package:ssh_app/theme/tokens.dart';
import 'package:uuid/uuid.dart';
import 'package:xterm/xterm.dart';

/// Written before the first output of the shell that replaces a lost one.
const reconnectedBanner = '--- reconnected, new shell ---';

/// Turns off what the lost shell's program may have switched on: the
/// alternate screen, a hidden cursor, mouse reporting, bracketed paste,
/// application cursor and keypad keys, and colors.
const _resetModes =
    '\x1b[?1049l\x1b[?25h\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l'
    '\x1b[?2004l\x1b[?1l\x1b>\x1b[0m';

/// Connects to [server] and runs its shell.
///
/// While connecting, a card over the terminal shows the steps; an unknown
/// host key is confirmed in a bottom sheet first.
class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({
    super.key,
    required this.server,
    this.sessionId,
    this.autoConnect = true,
    this.tabId,
    this.active = true,
    this.tabsBar,
    this.onBack,
    this.onClose,
  });

  final ServerConfig server;

  /// The tab this pane belongs to, which it reports its status to.
  final String? tabId;

  /// Whether this pane is the one on screen. The others stay mounted, so
  /// they keep their buffers, but do not take the keyboard.
  final bool active;

  /// The row of session tabs, shown under the bar.
  final Widget? tabsBar;

  /// Back goes here (to the host list) and leaves the session open. Without
  /// it, Back asks to disconnect and closes the screen.
  final VoidCallback? onBack;

  /// Called when the session has been closed, to remove its tab. Without
  /// it the screen is popped.
  final VoidCallback? onClose;

  /// Fixed session ID for tests. A new one is generated when null.
  final String? sessionId;

  /// Starts connecting when the screen opens. Tests that drive the
  /// connection state themselves turn it off.
  final bool autoConnect;

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

  /// Runs snippets in this terminal's shell and hides their exit-code
  /// markers from what the terminal shows.
  late final _runner = SnippetRunner(
    write: (text) => _session?.writeShell(utf8.encode(text)),
  );

  late final AutocompleteController _auto;

  /// The snippet running now, for the banner above the key bar.
  ({String name, int step, int total})? _running;

  /// Columns and rows, for the bar.
  final _gridSize = ValueNotifier<(int, int)>((80, 24));

  late ServerConfig _server = widget.server;
  late String _sessionId = widget.sessionId ?? const Uuid().v4();

  SSHSession? _shell;
  StreamSubscription<String>? _outputSub;

  /// Font size while a pinch is in progress; otherwise the saved size.
  double? _pinchFontSize;
  var _pinchBase = 14.0;
  var _pinchStart = 0.0;
  final Map<int, Offset> _pointers = {};
  var _opening = false;
  var _confirmingLeave = false;

  /// A connection attempt was started from this screen.
  var _attempted = false;

  /// The session reached "connected" at least once.
  var _wasConnected = false;

  /// Failure that did not come through the state stream.
  String? _startError;

  /// The shell did not open after sign-in.
  String? _shellError;
  HostKeyChallenge? _shownChallenge;

  /// The connection dropped; the next shell is announced as a new one.
  var _connectionLost = false;

  /// The shell ended on its own (the user typed `exit`), so no new one is
  /// opened.
  var _shellExited = false;

  ({String sessionId, ServerConfig server}) get _args =>
      (sessionId: _sessionId, server: _server);

  SSHConnectionSession? get _session =>
      ref.read(sshConnectionServiceProvider).getSession(_sessionId);

  @override
  void initState() {
    super.initState();
    final lister = RemoteDirectoryLister(
      exec: (command) async {
        final session = _session;
        if (session == null || !session.isConnected) {
          throw StateError('Not connected.');
        }
        return session.execute(command);
      },
    );
    final history = ref.read(commandHistoryProvider);
    _auto = AutocompleteController(
      terminal: _terminal,
      hostId: widget.server.id,
      history: history,
      engine: CompletionEngine(
        history: () => history.entries(widget.server.id),
        snippets: () => ref.read(snippetListProvider).asData?.value ?? const [],
        listDirectory: lister.list,
      ),
      sources: () {
        final settings = ref.read(appSettingsProvider);
        return CompletionSources(
          paths: settings.completePaths,
          history: settings.completeHistory,
          snippets: settings.completeSnippets,
          common: settings.completeCommon,
        );
      },
      enabled: () => ref.read(appSettingsProvider).autocomplete,
      send: (text) => _terminal.onOutput?.call(text),
    );
    _terminal.onOutput = (data) {
      _auto.onInput(data);
      _sendToShell(data);
    };
    _terminal.onPrivateOSC = _auto.handleOsc;
    _terminal.addListener(_auto.onTerminalChanged);
    _terminal.onResize = _onTerminalResize;
    _modifiers.addListener(_onModifiersChanged);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    if (widget.autoConnect && !kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    // A snippet still running is abandoned with the screen.
    _runner.cancel();
    _terminal.removeListener(_auto.onTerminalChanged);
    _auto.dispose();
    _ptySize.dispose();
    _gridSize.dispose();
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

  Future<void> _connect() async {
    if (!mounted) {
      return;
    }
    setState(() {
      _attempted = true;
      _startError = null;
      _shellError = null;
      _shellExited = false;
      _shownChallenge = null;
    });
    try {
      await ref.read(sshSessionControllerProvider(_args)).connect();
    } on SSHConnectionException {
      // Shown through the state stream and the connection log.
    } catch (error) {
      if (mounted) {
        setState(() => _startError = '$error');
      }
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
    // Widgets cannot change during layout; the bar updates after the frame.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _gridSize.value = (columns, rows);
      }
    });
  }

  void _sendPtySize(PtySize size) {
    _session?.resizeShell(
      size.columns,
      size.rows,
      size.pixelWidth,
      size.pixelHeight,
    );
  }

  void _reportStatus(SSHConnectionState? state) {
    final id = widget.tabId;
    if (id == null) return;
    ref
        .read(sessionTabsProvider.notifier)
        .setStatus(id, tabStatusFor(state, attempted: _attempted));
  }

  @override
  void didUpdateWidget(TerminalScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      if (widget.active) {
        _focusNode.requestFocus();
      } else {
        _focusNode.unfocus();
      }
    }
  }

  void _onConnectionState(SSHConnectionState? state) {
    _reportStatus(state);
    switch (state?.status) {
      case SSHConnectionStatus.awaitingHostKeyConfirmation:
        final challenge = state?.challenge;
        if (challenge != null) {
          _showHostKey(challenge);
        }
      case SSHConnectionStatus.connected:
        _wasConnected = true;
        _recordConnected();
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

  void _showHostKey(HostKeyChallenge challenge) {
    if (identical(_shownChallenge, challenge) || challenge.isCompleted) {
      return;
    }
    _shownChallenge = challenge;
    unawaited(showHostKeySheet(context, challenge));
  }

  void _recordConnected() {
    final at = ref.read(clockProvider)();
    unawaited(() async {
      try {
        await ref
            .read(serverListProvider.notifier)
            .recordConnected(_server.id, at);
      } catch (error) {
        debugPrint('Could not record the connection time: $error');
      }
    }());
  }

  Future<void> _ensureShell() async {
    if (_opening || _shell != null || _shellExited || _shellError != null) {
      return;
    }
    final session = _session;
    if (session == null || !session.isConnected) {
      return;
    }
    setState(() => _opening = true);
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
      _auto.reset();
      // The view may have changed size while the shell was opening.
      _ptySize.opened(columns, rows);
      if (_connectionLost) {
        _connectionLost = false;
        _terminal.write('$_resetModes\r\n$reconnectedBanner\r\n');
      }
      _outputSub = shell.stdout
          .map<List<int>>((chunk) => chunk)
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((text) => _terminal.write(_runner.feed(text)));
      unawaited(shell.done.then((_) => _onShellDone(shell)));
      unawaited(_runOnConnectSnippets());
    } catch (error) {
      if (mounted) {
        _shellError = '$error';
      }
    } finally {
      if (mounted) {
        setState(() => _opening = false);
      }
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
    setState(() => _shellExited = true);
    _terminal.write('\r\n[session closed]\r\n');
  }

  Future<void> _retry() async {
    final state = ref.read(sshSessionStateProvider(_args)).asData?.value;
    if (state?.isConnected == true && _shellError != null) {
      setState(() => _shellError = null);
      await _ensureShell();
      return;
    }
    await _refreshServer();
    await _connect();
  }

  /// Picks up edits to the host. A changed address needs a new session,
  /// since a session keeps the server it was made for.
  Future<void> _refreshServer() async {
    ServerConfig? latest;
    try {
      latest = await ref.read(vaultServiceProvider).getServer(_server.id);
    } catch (error) {
      debugPrint('Could not reload the host: $error');
    }
    if (!mounted || latest == null || latest == _server) {
      return;
    }
    final updated = latest;
    setState(() {
      _server = updated;
      _sessionId = const Uuid().v4();
    });
  }

  Future<void> _editHost() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ServerFormScreen(server: _server),
      ),
    );
    await _refreshServer();
  }

  void _showDetails() {
    unawaited(
      showConnectionLogSheet(
        context,
        (_) => Consumer(
          builder: (context, ref, _) => ConnectionLogView(
            entries:
                ref.watch(sshSessionLogProvider(_args)).asData?.value ??
                const [],
          ),
        ),
      ),
    );
  }

  /// Offers to add the shell integration script to the server's rc file.
  Future<void> _installShellIntegration() async {
    if (_shell == null || _terminal.isUsingAltBuffer) {
      _snackbar('Open a shell prompt first.');
      return;
    }
    final install = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Install shell integration?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _auto.marks.active
                    ? 'It is already working on this server.'
                    : 'This adds a few lines to ~/.bashrc or ~/.zshrc on the '
                          'server so the app knows where you type and which '
                          'folder you are in. Suggestions work without it, '
                          'but better with it. It runs in the shell below, '
                          'where you can see it.',
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.terminalBackground,
                  borderRadius: BorderRadius.circular(AppRadii.key),
                ),
                child: Text(
                  shellIntegrationScript.trim(),
                  style: const TextStyle(
                    fontFamily: AppFonts.mono,
                    fontSize: 10.5,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(_auto.marks.active ? 'Add again' : 'Install'),
          ),
        ],
      ),
    );
    if (install == true && mounted && _shell != null) {
      _terminal.onOutput?.call('${shellIntegrationInstallCommand()}\r');
    }
  }

  /// Opens the snippet list and runs the one picked in this terminal.
  Future<void> _openSnippets() async {
    final snippet = await showSnippetPicker(context);
    if (snippet != null && mounted) {
      await _runSnippet(snippet);
    }
  }

  /// Runs [snippet] in this terminal. Asks for its variables and shows the
  /// commands first when it has variables or asks first.
  ///
  /// With [automatic] (a snippet set to run on connect) nobody is there to
  /// type values, so a snippet with variables is not run; the user is told.
  Future<void> _runSnippet(Snippet snippet, {bool automatic = false}) async {
    if (_running != null) {
      _snackbar('A snippet is already running. Stop it first.');
      return;
    }
    if (_shell == null) {
      _snackbar('Connect first, then run the snippet.');
      return;
    }
    var values = <String, String>{};
    if (snippet.allVariables.isNotEmpty) {
      if (automatic) {
        _snackbar('"${snippet.name}" needs values. Run it from Snippets.');
        return;
      }
    }
    if (snippet.allVariables.isNotEmpty || snippet.askFirst) {
      final request = await showRunSheet(context, snippet: snippet);
      if (request == null || !mounted) {
        return;
      }
      values = request.values;
    }
    final List<({String command, WaitRule wait, int timeoutSeconds})> resolved;
    try {
      resolved = snippet.resolvedSteps(values);
    } on FormatException catch (error) {
      _snackbar(error.message);
      return;
    }
    final steps = [
      for (final step in resolved)
        RunStep(
          command: step.command,
          wait: step.wait,
          timeout: Duration(seconds: step.timeoutSeconds),
        ),
    ];
    setState(
      () => _running = (name: snippet.name, step: 1, total: steps.length),
    );
    final result = await _runner.run(
      steps,
      stopOnFailure: snippet.stopOnFailure,
      onStep: (index, status) {
        if (mounted && status == StepStatus.running) {
          setState(
            () => _running = (
              name: snippet.name,
              step: index + 1,
              total: steps.length,
            ),
          );
        }
      },
    );
    if (!mounted) {
      return;
    }
    setState(() => _running = null);
    if (result.status == RunStatus.failed) {
      final failedAt = result.steps.indexWhere(
        (s) => s == StepStatus.failed || s == StepStatus.timedOut,
      );
      _snackbar(
        '"${snippet.name}" failed at step ${failedAt + 1}'
        '${result.steps[failedAt] == StepStatus.timedOut ? ' (timed out)' : ''}.',
      );
    }
  }

  /// Runs the snippets set to run on connect for this host, one after the
  /// other, each time a shell opens.
  Future<void> _runOnConnectSnippets() async {
    try {
      final snippets = await ref.read(snippetListProvider.future);
      for (final snippet in snippets) {
        if (!mounted || _shell == null) return;
        if (snippet.runOnConnect.contains(_server.id)) {
          await _runSnippet(snippet, automatic: true);
        }
      }
    } catch (error) {
      debugPrint('Could not run the on-connect snippets: $error');
    }
  }

  void _snackbar(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text)));
    }
  }

  void _trackPointer(PointerEvent event) {
    _pointers[event.pointer] = event.position;
  }

  void _endPointer(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length < 2) {
      _pinchStart = 0;
      final size = _pinchFontSize;
      if (size != null) {
        _pinchFontSize = null;
        unawaited(
          ref
              .read(appSettingsProvider.notifier)
              .setHostFontSize(_server.id, size),
        );
      }
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
      _pinchBase =
          _pinchFontSize ??
          ref.read(appSettingsProvider).fontSizeFor(_server.id);
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
      _pinchFontSize = (_pinchBase * span / _pinchStart).clamp(8, 32);
    });
  }

  void _sendKey(TerminalKey key) {
    if (key == TerminalKey.arrowRight && _auto.acceptGhost()) {
      _focusNode.requestFocus();
      return;
    }
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
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.arrowRight &&
        !_modifiers.isArmed &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isAltPressed &&
        _auto.acceptGhost()) {
      return KeyEventResult.handled;
    }
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

  /// With "Volume keys" on: volume down arms CTRL, volume up sends ↑.
  bool _onHardwareKey(KeyEvent event) {
    if (!mounted ||
        !widget.active ||
        !ref.read(appSettingsProvider).volumeKeys ||
        ref.read(appLockProvider).locked) {
      return false;
    }
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) {
      return false;
    }
    final key = event.logicalKey;
    final down = key == LogicalKeyboardKey.audioVolumeDown;
    if (!down && key != LogicalKeyboardKey.audioVolumeUp) {
      return false;
    }
    if (event is KeyDownEvent) {
      if (down) {
        _modifiers.toggleCtrl();
      } else {
        _terminal.keyInput(TerminalKey.arrowUp);
      }
    } else if (event is KeyRepeatEvent && !down) {
      _terminal.keyInput(TerminalKey.arrowUp);
    }
    return true;
  }

  bool get _isLive {
    final state = ref.read(sshSessionStateProvider(_args)).asData?.value;
    return state != null &&
        (state.isConnected || state.status == SSHConnectionStatus.reconnecting);
  }

  /// Back and Disconnect. A live session asks first; anything else just
  /// stops and leaves.
  Future<void> _leave() async {
    if (_isLive) {
      await _confirmLeave();
      return;
    }
    await ref.read(sshSessionControllerProvider(_args)).disconnect();
    _finish();
  }

  /// The session is over: remove its tab, or pop the screen.
  void _finish() {
    if (!mounted) return;
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
    } else {
      Navigator.of(context).pop();
    }
  }

  /// The Back button: to the host list with the session still open, or,
  /// for a pane that is not in the workspace, the old ask-and-close.
  void _back() {
    final onBack = widget.onBack;
    if (onBack != null) {
      onBack();
    } else {
      unawaited(_leave());
    }
  }

  Future<void> _cancel() async {
    await ref.read(sshSessionControllerProvider(_args)).disconnect();
    if (mounted && !_wasConnected) {
      _finish();
    }
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
            widget.onClose == null
                ? 'Disconnect from ${_server.label} and close this terminal?'
                : 'Disconnect from ${_server.label}? Your other sessions '
                      'stay open.',
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
    _finish();
  }

  ConnectionCardModel? _cardModel(SSHConnectionState? state) {
    final startError = _startError;
    if (startError != null) {
      return ConnectionCardModel.from(
        state: SSHConnectionState.error(startError),
        server: _server,
      );
    }
    if (state == null) {
      return _attempted
          ? ConnectionCardModel.from(
              state: const SSHConnectionState.connecting(
                SSHConnectionStage.loadingCredentials,
              ),
              server: _server,
            )
          : null;
    }
    switch (state.status) {
      case SSHConnectionStatus.connected:
        if (_shell != null || _shellExited) {
          return null;
        }
        return ConnectionCardModel.from(
          state: state,
          server: _server,
          shellError: _shellError,
          openingShell: _opening,
        );
      case SSHConnectionStatus.disconnected:
        if (!_attempted && !_wasConnected) {
          return null;
        }
        return ConnectionCardModel.from(state: state, server: _server);
      default:
        return ConnectionCardModel.from(
          state: state,
          server: _server,
          wasConnected: _wasConnected,
        );
    }
  }

  static Color _statusColor(SSHConnectionState? state, bool attempted) {
    return switch (state?.status) {
      SSHConnectionStatus.connected => AppColors.accent,
      SSHConnectionStatus.connecting ||
      SSHConnectionStatus.awaitingHostKeyConfirmation ||
      SSHConnectionStatus.reconnecting => AppColors.warn,
      SSHConnectionStatus.error ||
      SSHConnectionStatus.disconnected => AppColors.error,
      null => attempted ? AppColors.warn : AppColors.muted,
    };
  }

  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(sshSessionStateProvider(_args));
    final settings = ref.watch(appSettingsProvider);
    final state = connection.asData?.value;

    ref.listen(sshSessionStateProvider(_args), (previous, next) {
      _onConnectionState(next.asData?.value);
    });

    final connected = state?.isConnected ?? false;
    if (connected &&
        _shell == null &&
        !_opening &&
        !_shellExited &&
        _shellError == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureShell());
    }

    final terminalTheme = settings.terminalTheme.theme;
    final fontSize = _pinchFontSize ?? settings.fontSizeFor(_server.id);
    final card = _cardModel(state);
    final statusColor = _statusColor(state, _attempted);

    final scaffold = Scaffold(
      backgroundColor: terminalTheme.background,
      resizeToAvoidBottomInset: true,
      appBar: _TerminalBar(
        server: _server,
        statusColor: statusColor,
        gridSize: _gridSize,
        onBack: _back,
        onSnippets: () => unawaited(_openSnippets()),
        onSettings: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
        onLog: _showDetails,
        onIntegration: () => unawaited(_installShellIntegration()),
        onDisconnect: () => unawaited(_leave()),
      ),
      body: Column(
        children: [
          widget.tabsBar ??
              _SessionTabs(server: _server, statusColor: statusColor),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
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
                          autofocus: widget.active,
                          deleteDetection: true,
                          theme: terminalTheme,
                          cursorType: settings.cursor.type,
                          textStyle: TerminalStyle(
                            fontSize: fontSize,
                            fontFamily: settings.font.fontFamily,
                            fontFamilyFallback: const [
                              ...AppFonts.fallback,
                              'monospace',
                            ],
                          ),
                          keyboardType: TextInputType.text,
                          onKeyEvent: _onKeyEvent,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: ListenableBuilder(
                      listenable: _auto,
                      builder: (context, _) => _GhostText(
                        controller: _auto,
                        viewKey: _terminalViewKey,
                        fontSize: fontSize,
                        fontFamily: settings.font.fontFamily,
                      ),
                    ),
                  ),
                ),
                if (card != null)
                  Positioned(
                    top: 12,
                    left: 12,
                    right: 12,
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 440),
                        child: ConnectionCard(
                          model: card,
                          onCancel: () => unawaited(_cancel()),
                          onDetails: _showDetails,
                          onRetry: () => unawaited(_retry()),
                          onEditHost: () => unawaited(_editHost()),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          ListenableBuilder(
            listenable: _auto,
            builder: (context, _) => SuggestionPanel(
              suggestions: _auto.suggestions,
              typed: _auto.line ?? '',
              onFill: (suggestion) {
                _auto.accept(suggestion);
                _focusNode.requestFocus();
              },
              onFillAndRun: (suggestion) {
                _auto.accept(suggestion, enter: true);
                _focusNode.requestFocus();
              },
            ),
          ),
          if (_running != null)
            _SnippetBanner(
              name: _running!.name,
              step: _running!.step,
              total: _running!.total,
              onStop: _runner.cancel,
            ),
          TerminalKeyboardBar(
            ctrl: _modifiers.ctrl,
            alt: _modifiers.alt,
            onToggleCtrl: _modifiers.toggleCtrl,
            onToggleAlt: _modifiers.toggleAlt,
            onKey: _sendKey,
            onText: _sendText,
            onPaste: () => unawaited(_pasteClipboard()),
            onSnippets: () => unawaited(_openSnippets()),
            layout: settings.keyBar,
            haptics: settings.haptics,
          ),
        ],
      ),
    );

    // In the workspace Back is handled there (it leaves the sessions open
    // and goes to the host list), so a hidden pane must not block it.
    if (widget.onBack != null) {
      return scaffold;
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          return;
        }
        unawaited(_leave());
      },
      child: scaffold,
    );
  }
}

/// The 50px bar: back, status dot, host name, size, snippets and menu.
class _TerminalBar extends StatelessWidget implements PreferredSizeWidget {
  const _TerminalBar({
    required this.server,
    required this.statusColor,
    required this.gridSize,
    required this.onBack,
    required this.onSnippets,
    required this.onSettings,
    required this.onLog,
    required this.onIntegration,
    required this.onDisconnect,
  });

  final ServerConfig server;
  final Color statusColor;
  final ValueListenable<(int, int)> gridSize;
  final VoidCallback onBack;
  final VoidCallback onSnippets;
  final VoidCallback onSettings;
  final VoidCallback onLog;
  final VoidCallback onIntegration;
  final VoidCallback onDisconnect;

  @override
  Size get preferredSize => const Size.fromHeight(AppSizes.terminalBar);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.bar,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: AppSizes.terminalBar,
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back),
                onPressed: onBack,
              ),
              StatusDot(color: statusColor, size: 10),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  server.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.text,
                  ),
                ),
              ),
              ValueListenableBuilder<(int, int)>(
                valueListenable: gridSize,
                builder: (context, size, _) => Text(
                  '${size.$1}×${size.$2}',
                  key: const ValueKey('terminal-grid-size'),
                  style: const TextStyle(
                    fontFamily: AppFonts.mono,
                    fontSize: 12,
                    color: AppColors.muted,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Snippets',
                icon: const Icon(Icons.code),
                onPressed: onSnippets,
              ),
              PopupMenuButton<String>(
                tooltip: 'More',
                icon: const Icon(Icons.more_vert),
                onSelected: (value) => switch (value) {
                  'settings' => onSettings(),
                  'log' => onLog(),
                  'integration' => onIntegration(),
                  _ => onDisconnect(),
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'settings',
                    child: ListTile(
                      leading: Icon(Icons.tune),
                      title: Text('Settings'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'log',
                    child: ListTile(
                      leading: Icon(Icons.receipt_long),
                      title: Text('Connection log'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'integration',
                    child: ListTile(
                      leading: Icon(Icons.auto_fix_high),
                      title: Text('Shell integration'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'disconnect',
                    child: ListTile(
                      leading: Icon(
                        Icons.power_settings_new,
                        color: AppColors.error,
                      ),
                      title: Text(
                        'Disconnect',
                        style: TextStyle(color: AppColors.error),
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The row of session tabs under the bar. One session per screen for now;
/// several come with multiple sessions.
class _SessionTabs extends StatelessWidget {
  const _SessionTabs({required this.server, required this.statusColor});

  final ServerConfig server;
  final Color statusColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      decoration: const BoxDecoration(
        color: AppColors.bar,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.key),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusDot(color: statusColor),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                server.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: AppColors.text),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows the snippet that is running, above the key bar.
class _SnippetBanner extends StatelessWidget {
  const _SnippetBanner({
    required this.name,
    required this.step,
    required this.total,
    required this.onStop,
  });

  final String name;
  final int step;
  final int total;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.accentSoft,
      child: Padding(
        padding: const EdgeInsets.only(left: 14),
        child: Row(
          children: [
            const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '$name · step $step of $total',
                key: const ValueKey('snippet-banner'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(onPressed: onStop, child: const Text('Stop')),
          ],
        ),
      ),
    );
  }
}

/// The first suggestion, in grey, right after the cursor.
class _GhostText extends StatelessWidget {
  const _GhostText({
    required this.controller,
    required this.viewKey,
    required this.fontSize,
    required this.fontFamily,
  });

  final AutocompleteController controller;
  final GlobalKey<TerminalViewState> viewKey;
  final double fontSize;
  final String fontFamily;

  @override
  Widget build(BuildContext context) {
    final suffix = controller.ghost?.insert.split('\n').first;
    final view = viewKey.currentState;
    if (suffix == null || suffix.isEmpty || view == null || !view.mounted) {
      return const SizedBox.shrink();
    }
    final render = view.renderTerminal;
    if (!render.hasSize) {
      return const SizedBox.shrink();
    }
    final offset = render.cursorOffset;
    final cell = render.cellSize;
    // Off screen when scrolled back.
    if (offset.dy < 0 || offset.dy + cell.height > render.size.height + 1) {
      return const SizedBox.shrink();
    }
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned(
          left: offset.dx,
          top: offset.dy,
          right: 0,
          height: cell.height,
          child: Text(
            suffix,
            key: const ValueKey('ghost-text'),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            style: TextStyle(
              fontFamily: fontFamily,
              fontFamilyFallback: const [...AppFonts.fallback, 'monospace'],
              fontSize: fontSize,
              height: 1.2,
              color: AppColors.muted.withValues(alpha: 0.7),
            ),
          ),
        ),
      ],
    );
  }
}
