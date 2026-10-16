import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
// TerminalViewState.renderTerminal is public API, but xterm does not export
// its type.
// ignore: implementation_imports
import 'package:xterm/src/ui/render.dart' show RenderTerminal;
import 'package:xterm/xterm.dart';

/// The text of [range] in [buffer], as plain text for the clipboard.
///
/// Empty cells inside a line become spaces, trailing whitespace is trimmed
/// from every line, blank lines at the end are dropped, and lines the
/// terminal wrapped are joined back together.
String terminalSelectionText(Buffer buffer, BufferRange range) {
  final selection = range.normalized;
  final lines = <String>[];
  final current = StringBuffer();
  var first = true;
  for (final segment in selection.toSegments()) {
    if (segment.line < 0 || segment.line >= buffer.lines.length) {
      continue;
    }
    final line = buffer.lines[segment.line];
    if (!first && !line.isWrapped) {
      lines.add(current.toString().trimRight());
      current.clear();
    }
    first = false;
    final start = math.max(segment.start ?? 0, 0);
    final end = math.min(segment.end ?? line.length, line.length);
    for (var i = start; i < end; i++) {
      final codePoint = line.getCodePoint(i);
      // The cell after a wide character is part of it.
      if (codePoint == 0 && i > 0 && line.getWidth(i - 1) == 2) {
        continue;
      }
      current.writeCharCode(codePoint == 0 ? 0x20 : codePoint);
    }
  }
  lines.add(current.toString().trimRight());
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines.join('\n');
}

/// Copy and paste for a [TerminalView].
///
/// [TerminalView] starts and clears selections itself: a long press selects
/// the word under the finger (moving the finger extends it by words) and a
/// tap clears it. This adds a drag handle at each end of the selection and a
/// floating Copy / Select all / Paste toolbar, and shows Paste on a long press
/// over empty space. Selections are anchored to buffer lines, so they work in
/// the scrollback too.
class TerminalSelectionOverlay extends StatefulWidget {
  const TerminalSelectionOverlay({
    super.key,
    required this.terminal,
    required this.controller,
    required this.scrollController,
    required this.terminalViewKey,
    required this.onPaste,
    required this.child,
  });

  final Terminal terminal;
  final TerminalController controller;
  final ScrollController scrollController;

  /// Key of the [TerminalView] in [child].
  final GlobalKey<TerminalViewState> terminalViewKey;

  /// Pastes the clipboard into the terminal.
  final Future<void> Function() onPaste;

  /// The [TerminalView] the selection belongs to.
  final Widget child;

  @override
  State<TerminalSelectionOverlay> createState() =>
      _TerminalSelectionOverlayState();
}

enum _SelectionEnd { start, end }

/// Height a Material selection toolbar needs above or below its anchor,
/// margins included.
const _toolbarRoom = 60.0;

class _TerminalSelectionOverlayState extends State<TerminalSelectionOverlay> {
  final _stackKey = GlobalKey();

  _SelectionEnd? _dragging;

  /// From the finger to the selection end being dragged, so that end does
  /// not jump to the finger when the drag starts.
  var _dragOffset = Offset.zero;
  Offset? _dragPosition;
  Timer? _autoScroll;
  var _autoScrollDirection = 0;

  /// Where a long press over empty space opened the Paste menu, in this
  /// widget's coordinates.
  Offset? _menuPosition;
  Timer? _pressTimer;
  int? _pressPointer;
  Offset? _pressStart;

  var _hadSelection = false;
  var _refreshScheduled = false;

  @override
  void initState() {
    super.initState();
    _listen(widget);
  }

  @override
  void didUpdateWidget(TerminalSelectionOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.scrollController != widget.scrollController ||
        oldWidget.terminal != widget.terminal) {
      _unlisten(oldWidget);
      _listen(widget);
    }
  }

  @override
  void dispose() {
    _unlisten(widget);
    _autoScroll?.cancel();
    _pressTimer?.cancel();
    super.dispose();
  }

  void _listen(TerminalSelectionOverlay widget) {
    widget.controller.addListener(_onSelectionChanged);
    widget.scrollController.addListener(_refresh);
    widget.terminal.addListener(_onTerminalChanged);
  }

  void _unlisten(TerminalSelectionOverlay widget) {
    widget.controller.removeListener(_onSelectionChanged);
    widget.scrollController.removeListener(_refresh);
    widget.terminal.removeListener(_onTerminalChanged);
  }

  RenderTerminal? get _render {
    final view = widget.terminalViewKey.currentState;
    if (view == null || !view.mounted) {
      return null;
    }
    final render = view.renderTerminal;
    return render.hasSize ? render : null;
  }

  void _onSelectionChanged() {
    final hasSelection = widget.controller.selection != null;
    if (hasSelection && !_hadSelection) {
      HapticFeedback.selectionClick();
      _menuPosition = null;
    }
    _hadSelection = hasSelection;
    _refresh();
  }

  /// Output and resizes move the selection on screen, which is only known
  /// once the terminal has been laid out again.
  void _onTerminalChanged() {
    if (widget.controller.selection == null || _refreshScheduled) {
      return;
    }
    _refreshScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      if (mounted) {
        setState(() {});
      }
    });
  }

  void _refresh() {
    if (!mounted) {
      return;
    }
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      _onTerminalChanged();
      return;
    }
    setState(() {});
  }

  Offset _toStack(RenderTerminal render, Offset local) {
    final global = render.localToGlobal(local);
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    return stack == null ? global : stack.globalToLocal(global);
  }

  /// The boundary between two cells closest to [local], a point in the
  /// terminal's coordinates. Its column runs up to the terminal width, so a
  /// selection can end after the last column.
  CellOffset _boundaryAt(RenderTerminal render, Offset local) {
    final row = render.getCellOffset(local).y;
    final rowStart = render.getOffset(CellOffset(0, row)).dx;
    final column = ((local.dx - rowStart) / render.cellSize.width)
        .round()
        .clamp(0, widget.terminal.viewWidth);
    return CellOffset(column, row);
  }

  void _startDrag(_SelectionEnd end, Offset global) {
    final render = _render;
    final selection = widget.controller.selection?.normalized;
    if (render == null || selection == null) {
      return;
    }
    final cell = end == _SelectionEnd.start ? selection.begin : selection.end;
    final target = render.localToGlobal(
      render.getOffset(cell) + Offset(0, render.lineHeight / 2),
    );
    _dragOffset = target - global;
    _dragPosition = global;
    setState(() => _dragging = end);
  }

  void _drag(Offset global) {
    _dragPosition = global;
    _moveDraggedEnd();
    _updateAutoScroll();
  }

  void _endDrag() {
    _autoScroll?.cancel();
    _autoScroll = null;
    _dragPosition = null;
    if (mounted) {
      setState(() => _dragging = null);
    }
  }

  void _moveDraggedEnd() {
    final render = _render;
    final dragging = _dragging;
    final position = _dragPosition;
    final selection = widget.controller.selection?.normalized;
    if (render == null ||
        dragging == null ||
        position == null ||
        selection == null) {
      return;
    }
    final boundary = _boundaryAt(
      render,
      render.globalToLocal(position + _dragOffset),
    );
    var begin = selection.begin;
    var end = selection.end;
    if (dragging == _SelectionEnd.start) {
      begin = boundary;
    } else {
      end = boundary;
    }
    if (end.isBefore(begin)) {
      // Dragged past the other end: the handle under the finger swaps roles.
      (begin, end) = (end, begin);
      _dragging = dragging == _SelectionEnd.start
          ? _SelectionEnd.end
          : _SelectionEnd.start;
    }
    if (begin == end || (begin == selection.begin && end == selection.end)) {
      return;
    }
    final buffer = widget.terminal.buffer;
    widget.controller.setSelection(
      buffer.createAnchorFromOffset(begin),
      buffer.createAnchorFromOffset(end),
    );
  }

  /// Scrolls while a handle is held at the top or bottom edge, so a selection
  /// can be extended into the scrollback.
  void _updateAutoScroll() {
    final render = _render;
    final position = _dragPosition;
    if (render == null || position == null) {
      return;
    }
    final y = render.globalToLocal(position + _dragOffset).dy;
    final edge = render.lineHeight;
    _autoScrollDirection = y < edge
        ? -1
        : y > render.size.height - edge
        ? 1
        : 0;
    if (_autoScrollDirection == 0) {
      _autoScroll?.cancel();
      _autoScroll = null;
      return;
    }
    _autoScroll ??= Timer.periodic(
      const Duration(milliseconds: 50),
      (_) => _autoScrollStep(),
    );
  }

  void _autoScrollStep() {
    final render = _render;
    final scroll = widget.scrollController;
    if (render == null ||
        _dragging == null ||
        _autoScrollDirection == 0 ||
        !scroll.hasClients) {
      _autoScroll?.cancel();
      _autoScroll = null;
      return;
    }
    final position = scroll.position;
    final target = (position.pixels + _autoScrollDirection * render.lineHeight)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target == position.pixels) {
      return;
    }
    position.jumpTo(target);
    _moveDraggedEnd();
  }

  void _onPointerDown(PointerDownEvent event) {
    _closeMenu();
    if (_pressPointer != null) {
      // A second finger: a pinch, not a long press.
      _cancelPress();
      return;
    }
    _pressPointer = event.pointer;
    _pressStart = event.position;
    _pressTimer = Timer(
      // Lets TerminalView's own long press select a word first.
      kLongPressTimeout + const Duration(milliseconds: 50),
      () => _openMenuIfNothingSelected(event.localPosition),
    );
  }

  void _onPointerMove(PointerMoveEvent event) {
    final start = _pressStart;
    if (event.pointer == _pressPointer &&
        start != null &&
        (event.position - start).distance > kTouchSlop) {
      _cancelPress();
    }
  }

  void _onPointerEnd(PointerEvent event) {
    if (event.pointer == _pressPointer) {
      _cancelPress();
    }
  }

  void _cancelPress() {
    _pressTimer?.cancel();
    _pressTimer = null;
    _pressPointer = null;
    _pressStart = null;
  }

  void _openMenuIfNothingSelected(Offset local) {
    _pressTimer = null;
    if (!mounted || widget.controller.selection != null) {
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => _menuPosition = local);
  }

  void _closeMenu() {
    if (_menuPosition != null) {
      setState(() => _menuPosition = null);
    }
  }

  Future<void> _copy() async {
    final selection = widget.controller.selection;
    if (selection == null) {
      return;
    }
    final text = terminalSelectionText(widget.terminal.buffer, selection);
    widget.controller.clearSelection();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Copied'),
          duration: Duration(milliseconds: 1500),
        ),
      );
  }

  void _selectAll() {
    final buffer = widget.terminal.buffer;
    _menuPosition = null;
    widget.controller.setSelection(
      buffer.createAnchor(0, 0),
      buffer.createAnchor(widget.terminal.viewWidth, buffer.lines.length - 1),
    );
  }

  Future<void> _paste() async {
    widget.controller.clearSelection();
    _closeMenu();
    await widget.onPaste();
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerEnd,
        onPointerCancel: _onPointerEnd,
        child: widget.child,
      ),
    ];
    final render = _render;
    final selection = widget.controller.selection?.normalized;
    if (render != null && selection != null) {
      children.addAll(_selectionControls(render, selection));
    } else if (render != null && _menuPosition != null) {
      final at = _menuPosition!;
      children.add(
        _toolbar(
          above: at - Offset(0, render.lineHeight),
          below: at + Offset(0, render.lineHeight),
          withCopy: false,
        ),
      );
    }
    return Stack(key: _stackKey, fit: StackFit.expand, children: children);
  }

  List<Widget> _selectionControls(
    RenderTerminal render,
    BufferRange selection,
  ) {
    final lineHeight = render.lineHeight;
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    final size = stack != null && stack.hasSize ? stack.size : render.size;

    // Bottom corners of the selection's first and last cell.
    final start = _toStack(
      render,
      render.getOffset(selection.begin) + Offset(0, lineHeight),
    );
    final end = _toStack(
      render,
      render.getOffset(selection.end) + Offset(0, lineHeight),
    );
    bool visible(Offset point) =>
        point.dy >= lineHeight / 2 && point.dy <= size.height + lineHeight / 2;

    final handleHeight = materialTextSelectionHandleControls
        .getHandleSize(lineHeight)
        .height;
    final x = selection.begin.y == selection.end.y
        ? (start.dx + end.dx) / 2
        : size.width / 2;
    var above = (start.dy - lineHeight).clamp(0.0, size.height);
    var below = end.dy + handleHeight;
    if (above < _toolbarRoom && below > size.height - _toolbarRoom) {
      // The selection fills the view, so the toolbar goes in the middle.
      above = math.max(size.height / 2, _toolbarRoom);
      below = above;
    }
    return [
      if (visible(start)) _handle(_SelectionEnd.start, start, lineHeight),
      if (visible(end)) _handle(_SelectionEnd.end, end, lineHeight),
      if (_dragging == null)
        _toolbar(
          above: Offset(x, above),
          below: Offset(x, below.clamp(0.0, size.height)),
          withCopy: true,
        ),
    ];
  }

  Widget _handle(_SelectionEnd end, Offset point, double lineHeight) {
    final type = end == _SelectionEnd.start
        ? TextSelectionHandleType.left
        : TextSelectionHandleType.right;
    final controls = materialTextSelectionHandleControls;
    final size = controls.getHandleSize(lineHeight);
    final anchor = controls.getHandleAnchor(type, lineHeight);
    // Grows the touch target around the small handle.
    final padX = math.max((kMinInteractiveDimension - size.width) / 2, 0.0);
    final padY = math.max((kMinInteractiveDimension - size.height) / 2, 0.0);
    return Positioned(
      left: point.dx - anchor.dx - padX,
      top: point.dy - anchor.dy - padY,
      child: GestureDetector(
        key: ValueKey('terminal-selection-${end.name}-handle'),
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onPanStart: (details) => _startDrag(end, details.globalPosition),
        onPanUpdate: (details) => _drag(details.globalPosition),
        onPanEnd: (_) => _endDrag(),
        onPanCancel: _endDrag,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: padX, vertical: padY),
          child: controls.buildHandle(context, type, lineHeight),
        ),
      ),
    );
  }

  Widget _toolbar({
    required Offset above,
    required Offset below,
    required bool withCopy,
  }) {
    return Positioned.fill(
      child: AdaptiveTextSelectionToolbar.buttonItems(
        anchors: TextSelectionToolbarAnchors(
          primaryAnchor: above,
          secondaryAnchor: below,
        ),
        buttonItems: [
          if (withCopy)
            ContextMenuButtonItem(
              type: ContextMenuButtonType.copy,
              onPressed: _copy,
            ),
          ContextMenuButtonItem(
            type: ContextMenuButtonType.selectAll,
            onPressed: _selectAll,
          ),
          ContextMenuButtonItem(
            type: ContextMenuButtonType.paste,
            onPressed: _paste,
          ),
        ],
      ),
    );
  }
}
