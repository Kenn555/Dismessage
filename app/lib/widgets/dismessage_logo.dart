import 'package:flutter/material.dart';

import '../branding/logo_geometry.dart';

/// The Dismessage logo, drawn (crisp at any size, no image asset).
class DismessageLogo extends StatelessWidget {
  const DismessageLogo({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Dismessage',
    image: true,
    child: CustomPaint(size: Size.square(size), painter: const _LogoPainter()),
  );
}

class _LogoPainter extends CustomPainter {
  const _LogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final square = Offset.zero & size;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        square,
        Radius.circular(LogoGeometry.backgroundRadius * s),
      ),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(LogoGeometry.gradientStart),
            Color(LogoGeometry.gradientEnd),
          ],
        ).createShader(square),
    );

    final bubble = Path()
      ..addRRect(
        RRect.fromLTRBR(
          LogoGeometry.bubbleLeft * s,
          LogoGeometry.bubbleTop * s,
          LogoGeometry.bubbleRight * s,
          LogoGeometry.bubbleBottom * s,
          Radius.circular(LogoGeometry.bubbleRadius * s),
        ),
      )
      ..addPolygon([
        for (final (x, y) in LogoGeometry.tail) Offset(x * s, y * s),
      ], true);
    canvas.drawPath(
      bubble,
      Paint()..color = const Color(LogoGeometry.bubbleColor),
    );

    for (final (x, y, r, opacity) in LogoGeometry.dots) {
      canvas.drawCircle(
        Offset(x * s, y * s),
        r * s,
        Paint()
          ..color = const Color(
            LogoGeometry.dotColor,
          ).withValues(alpha: opacity),
      );
    }
  }

  @override
  bool shouldRepaint(_LogoPainter oldDelegate) => false;
}
