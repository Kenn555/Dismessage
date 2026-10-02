// Renders every platform icon from LogoGeometry.
//
//   cd app && dart run tool/generate_icons.dart
//
// Shapes are rasterized with signed distance functions, so edges are
// anti-aliased at every size (no external tool needed).
import 'dart:io';
import 'dart:math' as math;

import 'package:dismessage/branding/logo_geometry.dart';
import 'package:image/image.dart' as img;
// The multi-resolution ICO encoder is not exported by the public API.
// ignore: implementation_imports
import 'package:image/src/formats/ico_encoder.dart' show IcoEncoder;

void main() {
  // Full icon: rounded gradient square + bubble.
  img.Image full(int size) => render(size);
  // Full-bleed square (maskable / adaptive layers clip it themselves).
  img.Image bleed(int size, double scale) =>
      render(size, roundedBackground: false, contentScale: scale);

  // Web.
  save('web/favicon.png', full(32));
  save('web/icons/Icon-192.png', full(192));
  save('web/icons/Icon-512.png', full(512));
  save('web/icons/Icon-maskable-192.png', bleed(192, 0.78));
  save('web/icons/Icon-maskable-512.png', bleed(512, 0.78));
  File('web/icons/logo.svg').writeAsStringSync(svg());

  // Android legacy icons (pre-8.0 launchers).
  const legacy = {
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };
  // Android adaptive icons: 108 dp layers, content kept in the 66 dp zone.
  const adaptive = {
    'mdpi': 108,
    'hdpi': 162,
    'xhdpi': 216,
    'xxhdpi': 324,
    'xxxhdpi': 432,
  };
  const res = 'android/app/src/main/res';
  legacy.forEach(
    (d, size) => save('$res/mipmap-$d/ic_launcher.png', full(size)),
  );
  adaptive.forEach((d, size) {
    save(
      '$res/mipmap-$d/ic_launcher_foreground.png',
      render(size, background: false, contentScale: 0.72),
    );
    save(
      '$res/mipmap-$d/ic_launcher_monochrome.png',
      render(size, background: false, contentScale: 0.72, monochrome: true),
    );
    save('$res/mipmap-$d/ic_launcher_background.png', bleed(size, 0));
  });

  // Windows: multi-resolution .ico.
  final ico = IcoEncoder().encodeImages([
    for (final size in [16, 24, 32, 48, 64, 128, 256]) full(size),
  ]);
  File('windows/runner/resources/app_icon.ico').writeAsBytesSync(ico);

  // Repository / store artwork.
  save('../assets/branding/logo-1024.png', full(1024));
  File('../assets/branding/logo.svg')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(svg());

  stdout.writeln('Icônes générées.');
}

void save(String path, img.Image image) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(img.encodePng(image));
}

/// Renders the logo on a [size]×[size] transparent canvas.
///
/// [contentScale] shrinks the bubble around the center (0 = no bubble).
/// [monochrome] draws the bubble only, with the dots cut out (Android 13
/// themed icons use the alpha channel only).
img.Image render(
  int size, {
  bool background = true,
  bool roundedBackground = true,
  double contentScale = 1,
  bool monochrome = false,
}) {
  final image = img.Image(width: size, height: size, numChannels: 4);
  final start = _rgb(LogoGeometry.gradientStart);
  final end = _rgb(LogoGeometry.gradientEnd);
  final dot = _rgb(LogoGeometry.dotColor);
  const white = (255.0, 255.0, 255.0);

  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final u = (x + 0.5) / size;
      final v = (y + 0.5) / size;
      final pixelU = 1 / size;
      var color = (0.0, 0.0, 0.0);
      var alpha = 0.0;

      void over((double, double, double) c, double a) {
        if (a <= 0) return;
        final outA = a + alpha * (1 - a);
        color = (
          (c.$1 * a + color.$1 * alpha * (1 - a)) / outA,
          (c.$2 * a + color.$2 * alpha * (1 - a)) / outA,
          (c.$3 * a + color.$3 * alpha * (1 - a)) / outA,
        );
        alpha = outA;
      }

      if (background) {
        final t = ((u + v) / 2).clamp(0.0, 1.0);
        final c = (
          start.$1 + (end.$1 - start.$1) * t,
          start.$2 + (end.$2 - start.$2) * t,
          start.$3 + (end.$3 - start.$3) * t,
        );
        final coverage = roundedBackground
            ? _cover(
                _roundBox(u, v, 0, 0, 1, 1, LogoGeometry.backgroundRadius),
                pixelU,
              )
            : 1.0;
        over(c, coverage);
      }

      if (contentScale > 0) {
        // Back to logo coordinates.
        final cu = (u - 0.5) / contentScale + 0.5;
        final cv = (v - 0.5) / contentScale + 0.5;
        final unit = pixelU / contentScale;
        final bubble = math.min(
          _roundBox(
            cu,
            cv,
            LogoGeometry.bubbleLeft,
            LogoGeometry.bubbleTop,
            LogoGeometry.bubbleRight,
            LogoGeometry.bubbleBottom,
            LogoGeometry.bubbleRadius,
          ),
          _triangle(cu, cv, LogoGeometry.tail),
        );
        var dots = 0.0;
        for (final (dx, dy, r, opacity) in LogoGeometry.dots) {
          final d =
              math.sqrt((cu - dx) * (cu - dx) + (cv - dy) * (cv - dy)) - r;
          dots = math.max(dots, _cover(d, unit) * opacity);
        }
        if (monochrome) {
          over(white, _cover(bubble, unit) * (1 - dots));
        } else {
          over(white, _cover(bubble, unit));
          over(dot, dots);
        }
      }

      image.setPixelRgba(
        x,
        y,
        color.$1.round(),
        color.$2.round(),
        color.$3.round(),
        (alpha * 255).round(),
      );
    }
  }
  return image;
}

/// Pixel coverage from a signed distance (negative = inside).
double _cover(double distance, double pixel) =>
    (0.5 - distance / pixel).clamp(0.0, 1.0);

double _roundBox(
  double px,
  double py,
  double l,
  double t,
  double r,
  double b,
  double radius,
) {
  final cx = (l + r) / 2, cy = (t + b) / 2;
  final qx = (px - cx).abs() - ((r - l) / 2 - radius);
  final qy = (py - cy).abs() - ((b - t) / 2 - radius);
  final outside = math.sqrt(
    math.pow(math.max(qx, 0), 2) + math.pow(math.max(qy, 0), 2),
  );
  return outside + math.min(math.max(qx, qy), 0) - radius;
}

/// Signed distance to a triangle (Inigo Quilez).
double _triangle(double px, double py, List<(double, double)> p) {
  final (x0, y0) = p[0];
  final (x1, y1) = p[1];
  final (x2, y2) = p[2];
  final e0 = (x1 - x0, y1 - y0),
      e1 = (x2 - x1, y2 - y1),
      e2 = (x0 - x2, y0 - y2);
  final v0 = (px - x0, py - y0),
      v1 = (px - x1, py - y1),
      v2 = (px - x2, py - y2);
  (double, double) proj((double, double) v, (double, double) e) {
    final k = ((v.$1 * e.$1 + v.$2 * e.$2) / (e.$1 * e.$1 + e.$2 * e.$2)).clamp(
      0.0,
      1.0,
    );
    return (v.$1 - e.$1 * k, v.$2 - e.$2 * k);
  }

  final pq0 = proj(v0, e0), pq1 = proj(v1, e1), pq2 = proj(v2, e2);
  final s = (e0.$1 * e2.$2 - e0.$2 * e2.$1).sign;
  double dot((double, double) a) => a.$1 * a.$1 + a.$2 * a.$2;
  final d0 = (dot(pq0), s * (v0.$1 * e0.$2 - v0.$2 * e0.$1));
  final d1 = (dot(pq1), s * (v1.$1 * e1.$2 - v1.$2 * e1.$1));
  final d2 = (dot(pq2), s * (v2.$1 * e2.$2 - v2.$2 * e2.$1));
  final minDist = math.min(d0.$1, math.min(d1.$1, d2.$1));
  final minSide = math.min(d0.$2, math.min(d1.$2, d2.$2));
  return -math.sqrt(minDist) * minSide.sign;
}

(double, double, double) _rgb(int argb) => (
  ((argb >> 16) & 0xff).toDouble(),
  ((argb >> 8) & 0xff).toDouble(),
  (argb & 0xff).toDouble(),
);

String _hex(int argb) =>
    '#${(argb & 0xffffff).toRadixString(16).padLeft(6, '0')}';

/// Vector version for the web loading screen and the repository.
String svg() {
  String n(double v) => (v * 100).toStringAsFixed(1);
  final tail = LogoGeometry.tail.map((p) => '${n(p.$1)},${n(p.$2)}').join(' ');
  final dots = LogoGeometry.dots
      .map(
        (d) =>
            '<circle cx="${n(d.$1)}" cy="${n(d.$2)}" r="${n(d.$3)}" '
            'fill="${_hex(LogoGeometry.dotColor)}" fill-opacity="${d.$4}"/>',
      )
      .join();
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">'
      '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">'
      '<stop offset="0" stop-color="${_hex(LogoGeometry.gradientStart)}"/>'
      '<stop offset="1" stop-color="${_hex(LogoGeometry.gradientEnd)}"/>'
      '</linearGradient></defs>'
      '<rect width="100" height="100" rx="${n(LogoGeometry.backgroundRadius)}" fill="url(#g)"/>'
      '<rect x="${n(LogoGeometry.bubbleLeft)}" y="${n(LogoGeometry.bubbleTop)}" '
      'width="${n(LogoGeometry.bubbleRight - LogoGeometry.bubbleLeft)}" '
      'height="${n(LogoGeometry.bubbleBottom - LogoGeometry.bubbleTop)}" '
      'rx="${n(LogoGeometry.bubbleRadius)}" fill="#fff"/>'
      '<polygon points="$tail" fill="#fff"/>'
      '$dots</svg>\n';
}
