import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/chat_session.dart';
import '../services/desktop_overlay.dart';
import '../services/live_fullscreen.dart';
import '../services/live_link.dart';

/// Width / height of [image], 4:3 until the first frame.
double liveAspectRatio(ui.Image? image) =>
    image == null || image.height == 0 ? 4 / 3 : image.width / image.height;

/// The last frame of a camera. Only this repaints when a frame comes.
class LiveSurface extends StatelessWidget {
  const LiveSurface({
    super.key,
    required this.image,
    this.fit = BoxFit.cover,
    this.placeholder,
  });

  final ValueListenable<ui.Image?> image;
  final BoxFit fit;

  /// Shown until the first frame.
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ColoredBox(
        color: Colors.black,
        child: ValueListenableBuilder<ui.Image?>(
          valueListenable: image,
          builder: (context, frame, _) {
            if (frame == null) {
              return placeholder ?? const SizedBox.expand();
            }
            return SizedBox.expand(
              child: RawImage(
                image: frame,
                fit: fit,
                filterQuality: FilterQuality.low,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The camera view with its buttons. A tap puts it in full screen.
class LiveViewCard extends StatelessWidget {
  const LiveViewCard({
    super.key = const Key('live-view'),
    required this.image,
    required this.onClose,
    this.onFullscreen,
  });

  final ValueListenable<ui.Image?> image;
  final VoidCallback onClose;
  final VoidCallback? onFullscreen;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            key: const Key('live-view-surface'),
            onTap: onFullscreen,
            child: MouseRegion(
              cursor: onFullscreen == null
                  ? MouseCursor.defer
                  : SystemMouseCursors.click,
              child: LiveSurface(
                image: image,
                placeholder: const Center(
                  child: CircularProgressIndicator(color: Colors.white54),
                ),
              ),
            ),
          ),
          Positioned(
            top: 2,
            right: 2,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onFullscreen != null)
                  _LiveViewButton(
                    key: const Key('live-fullscreen-button'),
                    tooltip: 'Plein écran (F11)',
                    icon: Icons.fullscreen_rounded,
                    onPressed: onFullscreen!,
                  ),
                _LiveViewButton(
                  key: const Key('live-close'),
                  tooltip: 'Fermer la vue',
                  icon: Icons.close_rounded,
                  onPressed: onClose,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A small button over the camera view.
class _LiveViewButton extends StatelessWidget {
  const _LiveViewButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => ExcludeFocus(
    child: IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black45,
        foregroundColor: Colors.white,
      ),
      iconSize: 18,
      icon: Icon(icon),
      onPressed: onPressed,
    ),
  );
}

/// Below this widget, the camera view is shown by the sidebar of the
/// conversations, not above the input.
class LiveViewInSidebar extends InheritedWidget {
  const LiveViewInSidebar({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LiveViewInSidebar>() != null;

  @override
  bool updateShouldNotify(LiveViewInSidebar oldWidget) => false;
}

/// Covers everything with the camera in full screen, above [child], which
/// stays built behind.
class LiveFullscreenHost extends StatelessWidget {
  const LiveFullscreenHost({
    super.key,
    required this.fullscreen,
    required this.child,
    this.panel,
  });

  final LiveFullscreen fullscreen;
  final Widget child;

  /// The conversation's panel, shown at the bottom of the full screen.
  final Widget Function(ChatSession session)? panel;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: fullscreen,
      builder: (context, _) {
        final session = fullscreen.session;
        final covered = session != null;
        return Stack(
          children: [
            Positioned.fill(
              child: Offstage(
                offstage: covered,
                // Nothing behind animates or takes the keyboard.
                child: TickerMode(
                  enabled: !covered,
                  child: ExcludeFocus(excluding: covered, child: child),
                ),
              ),
            ),
            if (session != null)
              Positioned.fill(
                child: _FullscreenView(
                  key: ValueKey(session.sid),
                  image: session.live.image,
                  onExit: fullscreen.exit,
                  panel: panel?.call(session),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _FullscreenView extends StatelessWidget {
  const _FullscreenView({
    super.key,
    required this.image,
    required this.onExit,
    this.panel,
  });

  final LiveImage image;
  final VoidCallback onExit;
  final Widget? panel;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    final key = event.logicalKey;
    final leaves =
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.f11 ||
        (key == LogicalKeyboardKey.keyF &&
            keyboard.isControlPressed &&
            keyboard.isAltPressed);
    if (!leaves) return KeyEventResult.ignored;
    if (event is KeyDownEvent) onExit();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const Key('live-fullscreen'),
      color: Colors.black,
      child: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                key: const Key('live-fullscreen-surface'),
                onTap: onExit,
                child: LiveSurface(
                  image: image,
                  fit: BoxFit.contain,
                  placeholder: const Center(
                    child: CircularProgressIndicator(color: Colors.white54),
                  ),
                ),
              ),
            ),
            // The conversation goes on: its panel, a third of the screen wide
            // as usual, at the bottom.
            if (panel case final panel?)
              Positioned(
                left: 0,
                right: 0,
                bottom: DesktopOverlay.panelMargin,
                child: SafeArea(
                  top: false,
                  child: Center(
                    child: FractionallySizedBox(
                      widthFactor: MediaQuery.sizeOf(context).width < 840
                          ? 1
                          : 1 / 3,
                      child: panel,
                    ),
                  ),
                ),
              ),
            Positioned(
                top: 16,
                right: 16,
                child: SafeArea(
                  // No tooltip: this is above the navigator and its overlay.
                  child: Semantics(
                    label: 'Quitter le plein écran',
                    child: IconButton.filledTonal(
                      key: const Key('live-fullscreen-exit'),
                      icon: const Icon(Icons.fullscreen_exit_rounded),
                      onPressed: onExit,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
