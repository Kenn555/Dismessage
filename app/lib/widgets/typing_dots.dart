import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Three dots pulsing in turn, shown while the peer pauses.
class TypingDots extends StatefulWidget {
  const TypingDots({super.key, this.color, this.size = 5});

  final Color? color;
  final double size;

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color =
        widget.color ?? DefaultTextStyle.of(context).style.color ?? Colors.grey;
    return Semantics(
      label: 'écrit…',
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++)
              Padding(
                padding: EdgeInsets.only(left: widget.size * 0.6),
                child: _dot(color, _phase(i)),
              ),
          ],
        ),
      ),
    );
  }

  /// 0..1 pulse, each dot shifted by a third of the cycle.
  double _phase(int index) {
    final t = (_controller.value - index / 3) % 1.0;
    return t < 0.5 ? math.sin(t * 2 * math.pi) : 0.0;
  }

  Widget _dot(Color color, double pulse) => Transform.translate(
    offset: Offset(0, -pulse * widget.size * 0.5),
    child: Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.35 + 0.65 * pulse),
        shape: BoxShape.circle,
      ),
    ),
  );
}
