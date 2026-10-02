import 'dart:async';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'typing_dots.dart';

/// Shows what the peer is typing, live.
///
/// New characters fade in, and a burst received in one frame is rolled out
/// progressively so the text flows instead of jumping. After [pauseDelay]
/// without change, animated dots appear right after the last character.
class LiveDraftBubble extends StatefulWidget {
  const LiveDraftBubble({
    super.key,
    required this.text,
    this.pauseDelay = const Duration(milliseconds: kPauseDotsMs),
  });

  final String text;
  final Duration pauseDelay;

  /// Fade-in duration of a new character.
  static const fadeDuration = Duration(milliseconds: 120);

  /// Time over which a burst of characters is rolled out.
  static const rollWindow = Duration(milliseconds: kDraftBatchMs * 2);

  @override
  State<LiveDraftBubble> createState() => _LiveDraftBubbleState();
}

class _LiveDraftBubbleState extends State<LiveDraftBubble>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  /// Full received text; only the revealed part is drawn.
  String _text = '';

  /// When each UTF-16 unit of [_text] was revealed; null = not yet shown.
  List<Duration?> _revealedAt = [];

  /// Monotonic clock, kept across ticker restarts.
  Duration _now = Duration.zero;
  Duration _clockOffset = Duration.zero;
  Duration _lastElapsed = Duration.zero;

  Timer? _pauseTimer;
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _text = widget.text;
    // Text present before the widget existed is shown at once.
    _revealedAt = List.filled(
      _text.length,
      -LiveDraftBubble.fadeDuration,
      growable: true,
    );
    _restartPauseTimer();
  }

  @override
  void didUpdateWidget(LiveDraftBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text == _text) return;
    _applyText(widget.text);
    _restartPauseTimer();
  }

  @override
  void dispose() {
    _pauseTimer?.cancel();
    _ticker.dispose();
    super.dispose();
  }

  void _applyText(String next) {
    final op = TextDiff.compute(_text, next);
    if (op == null) return;
    final isAppend = op.pos + op.del == _text.length;
    _revealedAt.replaceRange(
      op.pos,
      op.pos + op.del,
      List<Duration?>.filled(op.ins.length, null),
    );
    _text = next;
    if (!isAppend) {
      // Edits in the middle fade in in place, without rolling.
      for (var i = 0; i < _revealedAt.length; i++) {
        _revealedAt[i] ??= _now;
      }
    }
    if (!_ticker.isActive) {
      _clockOffset = _now;
      _lastElapsed = Duration.zero;
      _ticker.start();
    }
  }

  void _restartPauseTimer() {
    _pauseTimer?.cancel();
    if (_paused) setState(() => _paused = false);
    _pauseTimer = Timer(widget.pauseDelay, () {
      if (mounted) setState(() => _paused = true);
    });
  }

  void _onTick(Duration elapsed) {
    final dt = elapsed - _lastElapsed;
    _lastElapsed = elapsed;
    _now = _clockOffset + elapsed;

    final firstHidden = _revealedAt.indexOf(null);
    if (firstHidden >= 0) {
      final hidden = _revealedAt.length - firstHidden;
      final share =
          dt.inMicroseconds / LiveDraftBubble.rollWindow.inMicroseconds;
      var count = (hidden * share).ceil().clamp(1, hidden);
      var end = firstHidden + count;
      // Never reveal half of a surrogate pair.
      if (end < _text.length && _isLowSurrogate(_text.codeUnitAt(end))) end++;
      for (var i = firstHidden; i < end; i++) {
        _revealedAt[i] = _now;
      }
    }

    final settled = _revealedAt.every(
      (t) => t != null && _now - t >= LiveDraftBubble.fadeDuration,
    );
    if (settled) _ticker.stop();
    setState(() {});
  }

  static bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

  List<InlineSpan> _textSpans(TextStyle style) {
    final spans = <InlineSpan>[];
    final settled = StringBuffer();
    final fadeUs = LiveDraftBubble.fadeDuration.inMicroseconds;
    void flushSettled() {
      if (settled.isEmpty) return;
      spans.add(TextSpan(text: settled.toString()));
      settled.clear();
    }

    var i = 0;
    while (i < _text.length) {
      final revealed = _revealedAt[i];
      if (revealed == null) break;
      final width =
          i + 1 < _text.length && _isLowSurrogate(_text.codeUnitAt(i + 1))
          ? 2
          : 1;
      final char = _text.substring(i, i + width);
      final age = (_now - revealed).inMicroseconds / fadeUs;
      if (age >= 1) {
        settled.write(char);
      } else {
        flushSettled();
        final t = Curves.easeOut.transform(age.clamp(0.0, 1.0));
        final color = style.color ?? Colors.black;
        spans.add(
          TextSpan(
            text: char,
            style: TextStyle(color: color.withValues(alpha: color.a * t)),
          ),
        );
      }
      i += width;
    }
    flushSettled();
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    if (_text.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(
      context,
    ).textTheme.bodyLarge!.copyWith(color: scheme.onSurfaceVariant);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Text.rich(
          key: const Key('live-draft-text'),
          TextSpan(
            style: style,
            children: [
              ..._textSpans(style),
              if (_paused)
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: TypingDots(color: style.color),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
