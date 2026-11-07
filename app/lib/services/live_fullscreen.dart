import 'package:flutter/foundation.dart';

import 'chat_session.dart';
import 'connection_service.dart';
import 'desktop_overlay.dart';
import 'live_link.dart';
import 'window_fullscreen.dart';

/// The peer's camera in full screen, whatever the view it comes from: the
/// conversation, or the Windows panel, which comes back afterwards.
class LiveFullscreen extends ChangeNotifier {
  LiveFullscreen({
    required this.connection,
    this.overlay,
    Future<void> Function(bool on)? setSystem,
  }) : _setSystem = setSystem ?? platformSetFullscreen {
    connection.addListener(_onConnection);
    overlay?.onFullscreenShortcut = _onShortcut;
  }

  final ConnectionService connection;
  final DesktopOverlay? overlay;
  final Future<void> Function(bool on) _setSystem;

  ChatSession? _session;

  /// The panel's conversation, shown again on leaving.
  ChatSession? _panel;

  /// The conversation whose camera is in full screen, if any.
  ChatSession? get session => _session;

  bool get active => _session != null;

  Future<void> enter(ChatSession session) async {
    if (active || session.live.watch != LiveWatch.watching) return;
    final overlay = this.overlay;
    if (overlay != null && overlay.active) {
      _panel = overlay.session;
      await overlay.exit();
    }
    _session = session;
    session.addListener(_onSession);
    session.live.setFullView(true);
    notifyListeners();
    await _setSystem(true);
  }

  Future<void> exit() async {
    final session = _session;
    if (session == null) return;
    _session = null;
    session.removeListener(_onSession);
    // Does nothing if the view or the conversation just ended.
    session.live.setFullView(false);
    notifyListeners();
    await _setSystem(false);
    final panel = _panel;
    _panel = null;
    if (panel != null && connection.sessions.contains(panel)) {
      await overlay?.enter(panel);
    }
  }

  /// In or out of full screen.
  Future<void> toggle(ChatSession session) =>
      active ? exit() : enter(session);

  /// Ctrl+Alt+F, from the panel.
  void _onShortcut() {
    final session = _session ?? overlay?.session;
    if (session != null) toggle(session);
  }

  /// The camera was cut: nothing left to show.
  void _onSession() {
    if (_session?.live.watch != LiveWatch.watching) exit();
  }

  /// The conversation was closed.
  void _onConnection() {
    final session = _session;
    if (session != null && !connection.sessions.contains(session)) exit();
  }

  @override
  void dispose() {
    connection.removeListener(_onConnection);
    _session?.removeListener(_onSession);
    overlay?.onFullscreenShortcut = null;
    super.dispose();
  }
}
