import 'dart:async';
import 'dart:ui' as ui;

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../services/attachments.dart';
import '../../services/chat_session.dart';
import '../../services/clipboard_images.dart';
import '../../services/contacts_service.dart';
import '../../services/desktop_overlay.dart';
import '../../services/image_codec.dart';
import '../../services/live_fullscreen.dart';
import '../../services/live_link.dart';
import '../../theme/app_theme.dart';
import '../../widgets/bubble_shell.dart';
import '../../widgets/file_bubble.dart';
import '../../widgets/live_draft_bubble.dart';
import '../../widgets/live_view.dart';

/// Shows [child] (the whole app), or only the overlay panel while
/// [overlay] is active. The app stays built behind it: what is typed, the
/// scroll position and the open screens are kept.
class DesktopOverlayHost extends StatelessWidget {
  const DesktopOverlayHost({
    super.key,
    required this.overlay,
    required this.contacts,
    required this.child,
    this.fullscreen,
    this.clipboardImages,
    this.encodeImage = ImageCodec.encodeInBackground,
  });

  final DesktopOverlay overlay;
  final ContactsService contacts;
  final Widget child;
  final LiveFullscreen? fullscreen;

  /// Images and files pasted in the panel; the platform's when null.
  final ClipboardImages? clipboardImages;
  final ImageEncoderFn encodeImage;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: overlay,
      builder: (context, _) {
        final session = overlay.session;
        return Stack(
          children: [
            Positioned.fill(
              child: Offstage(
                offstage: session != null,
                // Hidden: nothing there may animate (each frame of the panel
                // costs a capture) nor take the keyboard.
                child: TickerMode(
                  enabled: session == null,
                  child: ExcludeFocus(excluding: session != null, child: child),
                ),
              ),
            ),
            if (session != null)
              Positioned.fill(
                child: _FrameMirror(
                  overlay: overlay,
                  child: OverlayPanel(
                    key: ValueKey(session.sid),
                    session: session,
                    contacts: contacts,
                    onExit: overlay.exit,
                    onHeight: overlay.resize,
                    onLiveView: overlay.setLiveView,
                    onFullscreen: fullscreen == null
                        ? null
                        : () => fullscreen!.enter(session),
                    clipboardImages: clipboardImages,
                    encodeImage: encodeImage,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Hands the panel's pixels to the runner, which shows them with their
/// per-pixel transparency ([DesktopOverlay.showFrame]).
///
/// After each drawn frame, at most [_minInterval] apart: a capture costs far
/// more than a frame. A capture still running makes the next ones wait, but
/// the latest always ends up on screen. A slow heartbeat repairs any capture
/// that failed or was lost, so that what is typed never stays invisible.
class _FrameMirror extends StatefulWidget {
  const _FrameMirror({required this.overlay, required this.child});

  final DesktopOverlay overlay;
  final Widget child;

  @override
  State<_FrameMirror> createState() => _FrameMirrorState();
}

class _FrameMirrorState extends State<_FrameMirror> {
  static const _minInterval = Duration(milliseconds: 33);
  static const _heartbeat = Duration(seconds: 1);

  final _boundary = GlobalKey();
  final _clock = Stopwatch()..start();
  Duration? _lastCapture;
  Timer? _delayed;
  Timer? _repair;
  bool _busy = false;
  bool _again = false;

  @override
  void initState() {
    super.initState();
    if (!widget.overlay.sendsFrames) return;
    _afterNextFrame();
    _repair = Timer.periodic(_heartbeat, (_) => _request());
  }

  void _afterNextFrame() => SchedulerBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    _request();
    _afterNextFrame();
  });

  void _request() {
    if (!mounted) return;
    if (_busy) {
      _again = true;
      return;
    }
    if (_delayed != null) return;
    final last = _lastCapture;
    final wait = last == null
        ? Duration.zero
        : _minInterval - (_clock.elapsed - last);
    if (wait <= Duration.zero) {
      unawaited(_capture());
    } else {
      _delayed = Timer(wait, () {
        _delayed = null;
        _request();
      });
    }
  }

  Future<void> _capture() async {
    _busy = true;
    _lastCapture = _clock.elapsed;
    try {
      final boundary =
          _boundary.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null || !boundary.hasSize || !mounted) return;
      final image = await boundary.toImage(
        pixelRatio: View.of(context).devicePixelRatio,
      );
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (data != null && mounted) {
          await widget.overlay.showFrame(
            image.width,
            image.height,
            data.buffer.asUint8List(),
          );
        }
      } finally {
        image.dispose();
      }
    } catch (_) {
      // Mid-frame, or the engine refused: the next frame or the heartbeat
      // will show it.
    } finally {
      _busy = false;
      if (_again) {
        _again = false;
        _request();
      }
    }
  }

  @override
  void dispose() {
    _delayed?.cancel();
    _repair?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(key: _boundary, child: widget.child);
}

/// The conversation on two lines: the peer's live typing in white (else
/// their last bubble), mine in blue just below. It is not a field (mouse
/// clicks go through the window) but the keyboard types into it: Enter
/// sends, Escape leaves. A long text wraps and the panel grows (up to
/// [DesktopOverlay.panelMaxLines] lines each, then the end shows).
///
/// The peer's camera, if shown, sits on the left at the panel's initial
/// height. Since the panel only has the keyboard, anything asking for an answer
/// shows on a line of its own with the keys to use. Those that open something
/// to the peer (my camera, saving a file) take a Ctrl combination: Enter is
/// what I press while typing, it must never answer them by accident.
class OverlayPanel extends StatefulWidget {
  const OverlayPanel({
    super.key,
    required this.session,
    required this.contacts,
    required this.onExit,
    this.onHeight,
    this.onLiveView,
    this.onFullscreen,
    this.clipboardImages,
    this.encodeImage = ImageCodec.encodeInBackground,
    this.inFullscreen = false,
  });

  /// Over the camera in full screen: as high as its text, wherever it is
  /// placed, and without the small view of what already fills the screen.
  final bool inFullscreen;

  final ChatSession session;
  final ContactsService contacts;
  final VoidCallback onExit;

  /// The height the panel needs (logical pixels), when it changes: the
  /// window follows.
  final ValueChanged<double>? onHeight;

  /// The size of the camera view in the top left corner, null without one.
  final ValueChanged<Size?>? onLiveView;

  /// Shows the peer's camera in full screen.
  final VoidCallback? onFullscreen;

  final ClipboardImages? clipboardImages;
  final ImageEncoderFn encodeImage;

  @override
  State<OverlayPanel> createState() => _OverlayPanelState();
}

class _OverlayPanelState extends State<OverlayPanel> {
  // Picks up what was being typed in the chat.
  late final _input = TextEditingController(text: _session.localDraft);
  late final _focus = FocusNode(onKeyEvent: _onKey);
  late final ClipboardImages _clipboard =
      widget.clipboardImages ?? platformClipboardImages();
  late final AppLifecycleListener _lifecycle;
  double _height = DesktopOverlay.panelHeight;

  /// Pasted, waiting for Enter or Escape.
  Attachments? _pending;
  bool _sending = false;

  /// A notice shown for a few seconds (a refusal, a limit…).
  String? _notice;
  Timer? _noticeTimer;
  StreamSubscription<String>? _notices;
  Size? _reportedLive;

  ChatSession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    _focus.addListener(_holdFocus);
    // autofocus is ignored when something else had the focus in the app:
    // what is typed would then go nowhere, and show nowhere.
    SchedulerBinding.instance.addPostFrameCallback((_) => _takeFocus());
    _lifecycle = AppLifecycleListener(onResume: _takeFocus);
    _notices = _session.live.notices.listen(_showNotice);
    _session.live.addListener(_reportLive);
    _session.live.image.addListener(_reportLive);
    _reportLive();
  }

  void _takeFocus() {
    if (mounted && !_focus.hasFocus) _focus.requestFocus();
  }

  /// The panel is the only thing that can be typed in, as long as the window
  /// has the keyboard (otherwise, the app suspends the focus by itself).
  void _holdFocus() {
    if (_focus.hasFocus) return;
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) return;
    SchedulerBinding.instance.addPostFrameCallback((_) => _takeFocus());
  }

  void _showNotice(String message) {
    if (!mounted) return;
    _noticeTimer?.cancel();
    setState(() => _notice = message);
    _noticeTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  @override
  void dispose() {
    _session.live.removeListener(_reportLive);
    _session.live.image.removeListener(_reportLive);
    _lifecycle.dispose();
    _notices?.cancel();
    _noticeTimer?.cancel();
    _pending?.discard();
    _focus.removeListener(_holdFocus);
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// The runner lets clicks reach the camera view, and only it.
  void _reportLive() {
    final size = _session.live.watch == LiveWatch.watching ? _liveSize : null;
    if (size == _reportedLive) return;
    final first = _reportedLive == null && size != null && !_liveLaidOut;
    _reportedLive = size;
    _liveLaidOut = true;
    widget.onLiveView?.call(size);
    // The first frame gives the real proportions: the text moves over.
    if (!first && mounted) setState(() {});
  }

  /// [_reportLive] already ran: it is no longer in [initState].
  bool _liveLaidOut = false;

  Size get _liveSize {
    const height = DesktopOverlay.panelHeight;
    return Size(height * liveAspectRatio(_session.live.image.value), height);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final down = event is KeyDownEvent;
    final keyboard = HardwareKeyboard.instance;
    final control = keyboard.isControlPressed && !keyboard.isAltPressed;
    if (key == LogicalKeyboardKey.escape) {
      if (down) {
        if (_pending != null) {
          _dropPending();
        } else {
          widget.onExit();
        }
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f11) {
      if (_session.live.watch != LiveWatch.watching) {
        return KeyEventResult.ignored;
      }
      if (down) widget.onFullscreen?.call();
      return KeyEventResult.handled;
    }
    if (control && !keyboard.isShiftPressed) {
      if (key == LogicalKeyboardKey.keyV) {
        if (down) _paste();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyO && _hasQuestion) {
        if (down) _answer(accept: true);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyN && _hasQuestion) {
        if (down) _answer(accept: false);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyK) {
        final live = _session.live;
        final on =
            live.share != LiveShare.idle && live.share != LiveShare.asked;
        if (!on && live.watch == LiveWatch.idle) return KeyEventResult.ignored;
        if (down) {
          if (on) {
            live.stopSharing();
          } else {
            live.stopWatching();
          }
        }
        return KeyEventResult.handled;
      }
    }
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    if (down) {
      if (_pending != null) {
        _sendPending();
      } else if (_session.sendMessage()) {
        _input.clear();
      }
    }
    return KeyEventResult.handled;
  }

  /// Something from the peer waits for my answer.
  bool get _hasQuestion =>
      _session.live.share == LiveShare.asked ||
      _session.pendingFiles.isNotEmpty;

  /// The camera question first: it comes before the files.
  void _answer({required bool accept}) {
    final live = _session.live;
    if (live.share == LiveShare.asked) {
      if (accept) {
        live.acceptRequest();
      } else {
        live.declineRequest();
      }
    } else if (accept) {
      _session.acceptAllPending();
    } else {
      _session.declineAllPending();
    }
  }

  /// Pictures and files wait for a confirmation; text is simply inserted.
  Future<void> _paste() async {
    final content = await _clipboard.read();
    if (!mounted || _session.peerLeft) {
      await content.discard();
      return;
    }
    if (!content.isEmpty) {
      await _pending?.discard();
      setState(() => _pending = content);
      return;
    }
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty || !mounted) return;
    final value = _input.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final next = value.text.replaceRange(selection.start, selection.end, text);
    if (next.length > kMaxTextLength) return;
    _input.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: selection.start + text.length),
    );
    _session.updateDraft(next);
  }

  void _dropPending() {
    _pending?.discard();
    setState(() => _pending = null);
  }

  Future<void> _sendPending() async {
    final content = _pending;
    if (content == null || _sending) return;
    setState(() => _sending = true);
    final notice = await sendAttachments(
      _session,
      content,
      encode: widget.encodeImage,
    );
    if (!mounted) return;
    setState(() {
      _pending = null;
      _sending = false;
    });
    if (notice != null) _showNotice(notice);
  }

  /// After each layout: the window takes the height of the text.
  void _onSize(Size size) {
    // Ceiling, but not for a float error (64.0000001).
    final height = (size.height - 0.01).ceilToDouble();
    if (!mounted || height == _height) return;
    _height = height;
    widget.onHeight?.call(height);
  }

  /// The window ended up lower than the text (it was resized behind our
  /// back, or a request was lost): every line must show, so ask again.
  void _checkWindow(double viewHeight) {
    if (viewHeight >= _height - 0.5 || _askedFor == viewHeight) return;
    _askedFor = viewHeight;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onHeight?.call(_height);
    });
  }

  /// The window height for which [_checkWindow] last asked: once per
  /// height, not at every frame.
  double? _askedFor;

  /// The peer's last two bubbles, the latest first.
  List<String> _lastFromPeer() => [
    for (final entry in _session.messages.reversed)
      if (!entry.fromMe) entrySnippet(entry),
  ].take(2).toList();

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).textTheme.titleMedium!.copyWith(height: 1.3);
    final peerStyle = base.copyWith(color: Colors.white);
    final mineStyle = base.copyWith(color: AppTheme.overlayMine);
    if (!widget.inFullscreen) _checkWindow(MediaQuery.sizeOf(context).height);
    final content = ListenableBuilder(
      // Not rebuilt by the camera's frames: only its surface is.
      listenable: Listenable.merge([_session, _input, _session.live]),
      builder: (context, _) {
        final watching =
            _session.live.watch == LiveWatch.watching && !widget.inFullscreen;
        return Stack(
          children: [
            // The ground fades out on all sides, the text does not.
            Positioned.fill(
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: AppTheme.overlayFadeVertical.createShader,
                child: const DecoratedBox(
                  decoration: BoxDecoration(gradient: AppTheme.overlayFade),
                ),
              ),
            ),
            if (watching) _liveView(),
            // No message in the panel, only this dot: a camera must
            // never stay on without any sign. Ctrl+K stops it.
            if (_session.live.share == LiveShare.sharing ||
                _session.live.share == LiveShare.starting)
              const Positioned(
                key: Key('overlay-sharing'),
                top: 6,
                right: 14,
                child: SizedBox.square(
                  dimension: 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.redAccent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.only(
                // The text starts where the side fade ends, or after
                // the camera.
                left: watching ? _liveLeftInset : 44,
                right: 44,
                top: DesktopOverlay.panelPadding,
                bottom: DesktopOverlay.panelPadding,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Line(style: peerStyle, child: _peerLine(peerStyle)),
                  const SizedBox(height: DesktopOverlay.panelGap),
                  _Line(
                    style: mineStyle,
                    child: _mine(mineStyle, enabled: !_session.peerLeft),
                  ),
                  ..._prompts(base),
                ],
              ),
            ),
          ],
        );
      },
    );
    if (widget.inFullscreen) {
      return Material(
        key: const Key('fullscreen-panel'),
        type: MaterialType.transparency,
        child: content,
      );
    }
    // As high as its text, from the top: the window follows (_onSize),
    // and while it catches up the rest stays transparent.
    return Material(
      key: const Key('overlay-panel'),
      type: MaterialType.transparency,
      child: OverflowBox(
        alignment: Alignment.topCenter,
        minHeight: 0,
        maxHeight: double.infinity,
        child: _OnSize(onSize: _onSize, child: content),
      ),
    );
  }

  double get _liveLeftInset => _liveSize.width + 12;

  /// The camera, as high as the panel was at first, even if a long text made
  /// it grow. A click reaches it: the runner stops letting clicks through
  /// while the mouse is over it.
  Widget _liveView() {
    return Positioned(
      left: 0,
      top: 0,
      width: _liveSize.width,
      height: _liveSize.height,
      child: GestureDetector(
        key: const Key('overlay-live'),
        onTap: widget.onFullscreen,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LiveSurface(image: _session.live.image),
        ),
      ),
    );
  }

  /// What asks for an answer, or tells something, one line each.
  List<Widget> _prompts(TextStyle base) {
    final style = base.copyWith(
      color: AppTheme.overlayPrompt,
      fontSize: (base.fontSize ?? 16) - 2,
    );
    final live = _session.live;
    final name = widget.contacts.label(_session.peer);
    final waiting = _session.pendingFiles;
    final pending = _pending;
    final lines = <(Key, String)>[
      if (live.share == LiveShare.asked)
        (
          const Key('overlay-live-request'),
          '📷 $name veut voir votre caméra · Ctrl+O : autoriser · '
              'Ctrl+N : refuser',
        ),
      if (waiting.isNotEmpty)
        (
          const Key('overlay-offer'),
          '📥 ${describeAttachments(0, waiting.length)} de $name '
              '(${formatFileSize(waiting.fold(0, (n, f) => n + f.size))})'
              '${live.share == LiveShare.asked ? '' : ' · Ctrl+O : accepter · Ctrl+N : refuser'}',
        ),
      if (pending != null)
        (
          const Key('overlay-paste'),
          _sending
              ? 'Envoi en cours…'
              : '📎 Envoyer ${describeAttachments(pending.images.length, pending.files.length)} '
                    '${pending.files.isEmpty ? '' : '(${formatFileSize(pending.filesSize)}) '}'
                    '? · Entrée : envoyer · Échap : annuler',
        ),
      if (_notice case final notice?) (const Key('overlay-notice'), notice),
    ];
    return [
      for (final (key, text) in lines) Text(text, key: key, style: style),
    ];
  }

  Widget _peerLine(TextStyle style) {
    if (_session.peerLeft) {
      return Text('Déconnecté', style: style.copyWith(color: Colors.white54));
    }
    // Only the peer's two latest: the message in progress (their typing,
    // else their last bubble) and the one before, dimmed above it.
    final draft = _session.remoteDraft;
    final last = _lastFromPeer();
    final Widget current;
    final String? previous;
    if (draft.isNotEmpty) {
      current = LiveDraftBubble(
        key: const Key('overlay-peer'),
        text: draft,
        style: style,
        framed: false,
      );
      previous = last.firstOrNull;
    } else {
      current = Text(
        last.firstOrNull ?? widget.contacts.label(_session.peer),
        key: const Key('overlay-last'),
        style: style.copyWith(
          color: last.isEmpty ? Colors.white38 : Colors.white,
        ),
      );
      previous = last.elementAtOrNull(1);
    }
    if (previous == null) return current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          previous,
          key: const Key('overlay-previous'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: style.copyWith(color: Colors.white54),
        ),
        current,
      ],
    );
  }

  /// My last bubble: it stays on my line once sent, until I type again.
  String? _lastFromMe() {
    for (final entry in _session.messages.reversed) {
      if (entry.fromMe) return entrySnippet(entry);
    }
    return null;
  }

  /// My typing: a blue label, no cursor, no frame.
  Widget _mine(TextStyle style, {required bool enabled}) {
    final last = _lastFromMe();
    return Stack(
      children: [
        if (_input.text.isEmpty)
          Text(
            last ?? (enabled ? 'Tapez pour écrire…' : ''),
            key: last == null ? null : const Key('overlay-sent'),
            style: style.copyWith(
              color: AppTheme.overlayMine.withValues(
                alpha: last == null ? 0.45 : 0.75,
              ),
            ),
          ),
        EditableText(
          key: const Key('overlay-input'),
          controller: _input,
          focusNode: _focus,
          autofocus: true,
          readOnly: !enabled,
          style: style,
          cursorColor: AppTheme.overlayMine,
          backgroundCursorColor: Colors.transparent,
          showCursor: false,
          enableInteractiveSelection: false,
          minLines: 1,
          maxLines: DesktopOverlay.panelMaxLines,
          keyboardType: TextInputType.multiline,
          inputFormatters: [LengthLimitingTextInputFormatter(kMaxTextLength)],
          onChanged: _session.updateDraft,
        ),
      ],
    );
  }
}

/// One side of the panel: at least one line high, at most
/// [DesktopOverlay.panelMaxLines]; a longer text shows its end.
class _Line extends StatelessWidget {
  const _Line({required this.style, required this.child});

  final TextStyle style;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    const slot = DesktopOverlay.panelLineHeight;
    final line = style.fontSize! * style.height!;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: line * DesktopOverlay.panelMaxLines + (slot - line),
      ),
      child: SingleChildScrollView(
        reverse: true,
        physics: const NeverScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: slot),
          child: Align(alignment: Alignment.centerLeft, child: child),
        ),
      ),
    );
  }
}

/// Reports the size of [child] after each layout where it changed.
class _OnSize extends SingleChildRenderObjectWidget {
  const _OnSize({required this.onSize, super.child});

  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderOnSize(onSize);

  @override
  void updateRenderObject(BuildContext context, _RenderOnSize renderObject) =>
      renderObject.onSize = onSize;
}

class _RenderOnSize extends RenderProxyBox {
  _RenderOnSize(this.onSize);

  ValueChanged<Size> onSize;
  Size? _reported;

  @override
  void performLayout() {
    super.performLayout();
    if (size == _reported) return;
    _reported = size;
    final current = size;
    // Not during the layout: the callback may talk to the runner.
    SchedulerBinding.instance.addPostFrameCallback((_) => onSize(current));
  }
}
