import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'chat_session.dart';
import 'connection_service.dart';

/// Windows: one conversation in a translucent panel over the other apps
/// (a third of the screen wide, two lines high, at the top), which mouse
/// clicks go through.
///
/// The window itself becomes that panel (`windows/runner/overlay.cpp`) and
/// keeps the keyboard: typing goes on while a video plays behind. Ctrl+Alt+D,
/// anywhere, enters or leaves the panel, or gives it the keyboard back after
/// a click behind it.
class DesktopOverlay extends ChangeNotifier {
  DesktopOverlay({
    required this.connection,
    MethodChannel? channel,
    bool? supported,
    bool? sendsFrames,
  }) : _channel = channel ?? const MethodChannel('dismessage/overlay'),
       supported = supported ?? _windows,
       sendsFrames = sendsFrames ?? _windows {
    if (this.supported) _channel.setMethodCallHandler(_onCall);
    connection.addListener(_onConnection);
  }

  static bool get _windows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// The panel: two lines (the peer's, mine) and a small padding, in
  /// logical pixels; the runner sizes the window to [panelHeight] and
  /// places it [panelMargin] below the top of the screen.
  static const panelLineHeight = 24.0;
  static const panelGap = 2.0;
  static const panelPadding = 7.0;
  static const panelHeight = panelPadding * 2 + panelLineHeight * 2 + panelGap;
  static const panelMargin = 12.0;

  /// A long text wraps: each side grows up to this many lines.
  static const panelMaxLines = 5;

  final ConnectionService connection;
  final MethodChannel _channel;

  /// Whether this platform has the panel (Windows).
  final bool supported;

  /// Whether the panel's pixels go to the runner ([showFrame]): the window
  /// cannot show Flutter's transparency otherwise. Off in widget tests.
  final bool sendsFrames;

  ChatSession? _session;

  /// Ctrl+Alt+F, anywhere, while the panel shows a camera.
  VoidCallback? onFullscreenShortcut;

  /// The conversation in the panel; null when it is not shown.
  ChatSession? get session => _session;

  bool get active => _session != null;

  Future<void> enter(ChatSession session) async {
    if (!supported || _session == session) return;
    _session = session;
    notifyListeners();
    try {
      await _channel.invokeMethod<void>('enter', {
        'height': panelHeight,
        'margin': panelMargin,
      });
    } on Exception {
      // The window could not change: stay in the normal view.
      _session = null;
      notifyListeners();
    }
  }

  Future<void> exit() async {
    if (_session == null) return;
    _session = null;
    notifyListeners();
    try {
      await _channel.invokeMethod<void>('exit');
    } on Exception {
      // Nothing more to undo.
    }
  }

  /// The panel's text needs [height] logical pixels (a long text wraps):
  /// the window grows or shrinks, from the top.
  Future<void> resize(double height) async {
    if (!active) return;
    try {
      await _channel.invokeMethod<void>('resize', {'height': height});
    } on Exception {
      // The panel keeps its size.
    }
  }

  /// The panel shows a camera in its top left corner, of this logical size
  /// (null: none). Clicks there reach the panel instead of going through the
  /// window, and the Ctrl+Alt+F shortcut works.
  Future<void> setLiveView(Size? size) async {
    if (!active) return;
    try {
      await _channel.invokeMethod<void>('liveView', {
        'width': size?.width ?? 0.0,
        'height': size?.height ?? 0.0,
      });
    } on Exception {
      // The view still shows; only clicking it is lost.
    }
  }

  /// Shows the panel as drawn: premultiplied RGBA, [width] × [height]
  /// physical pixels.
  Future<void> showFrame(int width, int height, Uint8List pixels) async {
    if (!active) return;
    try {
      await _channel.invokeMethod<void>('frame', {
        'width': width,
        'height': height,
        'pixels': pixels,
      });
    } on Exception {
      // The next frame will try again.
    }
  }

  /// The shortcut: leaves the panel, or shows the conversation on screen
  /// (else the latest one) in it.
  Future<void> toggle() async {
    if (active) return exit();
    final sessions = connection.sessions;
    final session =
        connection.active ?? (sessions.isEmpty ? null : sessions.last);
    if (session != null) await enter(session);
  }

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method == 'hotkey') await toggle();
    if (call.method == 'fullscreen') onFullscreenShortcut?.call();
    return null;
  }

  /// The conversation was closed: back to the normal window.
  void _onConnection() {
    final session = _session;
    if (session != null && !connection.sessions.contains(session)) exit();
  }

  @override
  void dispose() {
    connection.removeListener(_onConnection);
    if (supported) _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
