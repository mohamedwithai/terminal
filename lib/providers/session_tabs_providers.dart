import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh_app/models/server_config.dart';
import 'package:uuid/uuid.dart';

/// How a tab's connection is doing, for the dot on the tab.
enum TabStatus { idle, busy, connected, problem }

/// One open terminal session. Several can be open at once, to the same host
/// or to different ones.
class SessionTab {
  const SessionTab({
    required this.id,
    required this.server,
    this.status = TabStatus.idle,
  });

  final String id;
  final ServerConfig server;
  final TabStatus status;

  SessionTab copyWith({TabStatus? status}) =>
      SessionTab(id: id, server: server, status: status ?? this.status);
}

class SessionTabsState {
  const SessionTabsState({
    this.tabs = const [],
    this.activeId,
    this.visible = false,
  });

  final List<SessionTab> tabs;
  final String? activeId;

  /// The terminal workspace is on screen. Closing it (Back) leaves the
  /// sessions open.
  final bool visible;

  SessionTab? get active {
    for (final tab in tabs) {
      if (tab.id == activeId) return tab;
    }
    return null;
  }

  int get count => tabs.length;
}

final sessionTabsProvider =
    NotifierProvider<SessionTabsNotifier, SessionTabsState>(
      SessionTabsNotifier.new,
    );

/// The open sessions. A tab's terminal buffer and connection live in its
/// pane, which stays mounted while the tab exists, so closing a tab ends
/// that session and no other.
class SessionTabsNotifier extends Notifier<SessionTabsState> {
  @override
  SessionTabsState build() => const SessionTabsState();

  /// Opens a new session to [server], even if one is already open, and
  /// shows it.
  SessionTab open(ServerConfig server) {
    final tab = SessionTab(id: const Uuid().v4(), server: server);
    state = SessionTabsState(
      tabs: [...state.tabs, tab],
      activeId: tab.id,
      visible: true,
    );
    return tab;
  }

  /// The most recently opened tab for [serverId], if any.
  SessionTab? latestFor(String serverId) {
    for (final tab in state.tabs.reversed) {
      if (tab.server.id == serverId) return tab;
    }
    return null;
  }

  /// Opens the tab for [server] if there is one, else a new one.
  SessionTab openOrFocus(ServerConfig server) {
    final existing = latestFor(server.id);
    if (existing == null) return open(server);
    focus(existing.id);
    return existing;
  }

  /// Shows tab [id].
  void focus(String id) {
    if (!state.tabs.any((tab) => tab.id == id)) return;
    state = SessionTabsState(tabs: state.tabs, activeId: id, visible: true);
  }

  void show() {
    if (state.tabs.isEmpty) return;
    state = SessionTabsState(
      tabs: state.tabs,
      activeId: state.activeId ?? state.tabs.last.id,
      visible: true,
    );
  }

  /// Back to the host list. The sessions stay open.
  void hide() {
    if (!state.visible) return;
    state = SessionTabsState(tabs: state.tabs, activeId: state.activeId);
  }

  /// Closes tab [id]. Its session ends; the others are untouched.
  void close(String id) {
    final index = state.tabs.indexWhere((tab) => tab.id == id);
    if (index < 0) return;
    final tabs = [...state.tabs]..removeAt(index);
    var activeId = state.activeId;
    if (activeId == id) {
      // The neighbour to the left, or the first one left.
      activeId = tabs.isEmpty ? null : tabs[index > 0 ? index - 1 : 0].id;
    }
    state = SessionTabsState(
      tabs: tabs,
      activeId: activeId,
      visible: state.visible && tabs.isNotEmpty,
    );
  }

  /// Closes every tab of a host, for when the host is deleted.
  void closeForServer(String serverId) {
    for (final tab in [...state.tabs]) {
      if (tab.server.id == serverId) close(tab.id);
    }
  }

  /// A pane reports how its connection is doing.
  void setStatus(String id, TabStatus status) {
    final index = state.tabs.indexWhere((tab) => tab.id == id);
    if (index < 0 || state.tabs[index].status == status) return;
    final tabs = [...state.tabs];
    tabs[index] = tabs[index].copyWith(status: status);
    state = SessionTabsState(
      tabs: tabs,
      activeId: state.activeId,
      visible: state.visible,
    );
  }
}
