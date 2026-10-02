/// Single source of truth for the Dismessage logo.
///
/// Pure Dart (no Flutter import): used both by the in-app painter and by
/// `tool/generate_icons.dart`, which renders every platform icon.
///
/// Coordinates are in a 1×1 square, origin top-left.
abstract final class LogoGeometry {
  /// Brand colors (ARGB): gradient from top-left to bottom-right.
  static const int gradientStart = 0xFF5B5BD6;
  static const int gradientEnd = 0xFF8B5CF6;
  static const int bubbleColor = 0xFFFFFFFF;
  static const int dotColor = gradientStart;

  /// Corner radius of the rounded-square background.
  static const double backgroundRadius = 0.225;

  /// Speech bubble body.
  static const double bubbleLeft = 0.18;
  static const double bubbleTop = 0.22;
  static const double bubbleRight = 0.82;
  static const double bubbleBottom = 0.68;
  static const double bubbleRadius = 0.15;

  /// Tail of the bubble (bottom-left), as a triangle.
  static const List<(double, double)> tail = [
    (0.27, 0.62),
    (0.45, 0.62),
    (0.22, 0.81),
  ];

  /// The three typing dots: (x, y, radius, opacity).
  /// The last one is paler: someone is typing right now.
  static const List<(double, double, double, double)> dots = [
    (0.355, 0.45, 0.058, 1.0),
    (0.50, 0.45, 0.058, 1.0),
    (0.645, 0.45, 0.058, 0.4),
  ];
}
