import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/chat_session.dart';
import '../services/voice_recorder.dart';

/// One-line summary of a bubble, for reply quotes.
String entrySnippet(ChatEntry entry) => switch (entry) {
  ChatMessage(:final text) => text.replaceAll(RegExp(r'\s+'), ' ').trim(),
  ChatImage() => '📷 Photo',
  ChatVoice(:final duration) =>
    '🎤 Message vocal (${formatVoiceDuration(duration)})',
  ChatFile(:final name) => '📎 $name',
};

/// Wraps a bubble with what every bubble shares: alignment, swipe right to
/// reply, long press (or right click) for actions, the reaction badge and a
/// short highlight when a quote jumps to it.
class BubbleShell extends StatefulWidget {
  const BubbleShell({
    super.key,
    required this.entry,
    required this.child,
    this.onReply,
    this.onActions,
    this.highlighted = false,
  });

  final ChatEntry entry;
  final Widget child;
  final VoidCallback? onReply;
  final VoidCallback? onActions;
  final bool highlighted;

  /// Drag distance that triggers a reply.
  static const replyThreshold = 56.0;

  @override
  State<BubbleShell> createState() => _BubbleShellState();
}

class _BubbleShellState extends State<BubbleShell>
    with SingleTickerProviderStateMixin {
  /// Springs the bubble back after a swipe.
  late final AnimationController _back;
  double _dx = 0;
  double _releasedAt = 0;
  bool _armed = false;

  @override
  void initState() {
    super.initState();
    _back = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    )..addListener(() => setState(() => _dx = _back.value * _releasedAt));
  }

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (widget.onReply == null) return;
    _back.stop();
    setState(() {
      _dx = (_dx + details.delta.dx).clamp(0, BubbleShell.replyThreshold * 1.4);
    });
    final armed = _dx >= BubbleShell.replyThreshold;
    if (armed && !_armed) HapticFeedback.selectionClick();
    _armed = armed;
  }

  void _onDragEnd([DragEndDetails? _]) {
    if (_armed) widget.onReply?.call();
    _armed = false;
    _releasedAt = _dx;
    _back.reverse(from: 1);
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final mine = entry.fromMe;
    final scheme = Theme.of(context).colorScheme;
    final reaction = entry.reaction;
    final progress = (_dx / BubbleShell.replyThreshold).clamp(0.0, 1.0);

    Widget bubble = widget.child;
    if (reaction != null) {
      bubble = Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            bubble,
            Positioned(
              bottom: -16,
              left: mine ? 10 : null,
              right: mine ? null : 10,
              child: _ReactionBadge(
                key: ValueKey('reaction-${entry.id}'),
                emoji: reaction,
              ),
            ),
          ],
        ),
      );
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      color: widget.highlighted
          ? scheme.primary.withValues(alpha: 0.12)
          : Colors.transparent,
      child: GestureDetector(
        key: ValueKey('bubble-${entry.id}'),
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: _onDragEnd,
        onHorizontalDragCancel: _onDragEnd,
        onLongPress: widget.onActions,
        onSecondaryTap: widget.onActions,
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            if (_dx > 0)
              Opacity(
                opacity: progress,
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: CircleAvatar(
                    radius: 15,
                    backgroundColor: scheme.surfaceContainerHigh,
                    child: Icon(
                      Icons.reply_rounded,
                      size: 18,
                      color: scheme.primary,
                    ),
                  ),
                ),
              ),
            Transform.translate(
              offset: Offset(_dx, 0),
              child: Align(
                alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                child: bubble,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReactionBadge extends StatelessWidget {
  const _ReactionBadge({super.key, required this.emoji});

  final String emoji;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Text(emoji, style: const TextStyle(fontSize: 16)),
    );
  }
}

/// The quoted bubble shown above a reply (in the bubble or the composer).
class ReplyQuote extends StatelessWidget {
  const ReplyQuote({
    super.key,
    required this.author,
    required this.snippet,
    this.onBrand = false,
    this.onTap,
  });

  final String author;
  final String snippet;

  /// Drawn on the brand gradient (my own bubbles): white tones.
  final bool onBrand;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = onBrand ? Colors.white : scheme.primary;
    final text = onBrand
        ? Colors.white.withValues(alpha: 0.85)
        : scheme.onSurfaceVariant;
    return Material(
      color: onBrand
          ? Colors.white.withValues(alpha: 0.16)
          : scheme.primary.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: IntrinsicHeight(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 4, color: accent),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 10, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: accent,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        snippet,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: text),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
