import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// An image ready to be offered: re-encoded JPEG + tiny blurred preview.
class EncodedImage {
  const EncodedImage({
    required this.bytes,
    required this.width,
    required this.height,
    required this.preview,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final Uint8List preview;
}

class ImageCodecException implements Exception {
  const ImageCodecException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Prepares a picked picture for sending.
///
/// Re-encoding to JPEG also drops all metadata (EXIF, GPS position…).
abstract final class ImageCodec {
  static const _sides = [kMaxImageSide, 1024, 800, 640];
  static const _qualities = [82, 70, 60];

  /// Same as [encode], off the UI thread where the platform allows it.
  static Future<EncodedImage> encodeInBackground(Uint8List input) =>
      compute(encode, input);

  static EncodedImage encode(Uint8List input) {
    img.Image? decoded;
    try {
      decoded = img.decodeImage(input);
    } catch (_) {
      // Corrupted or truncated files make some decoders throw.
      decoded = null;
    }
    if (decoded == null) {
      throw const ImageCodecException('Format d’image non pris en charge.');
    }
    final source = _flatten(img.bakeOrientation(decoded))
      // Privacy: never forward EXIF (GPS position, device, date…).
      ..exif = img.ExifData();

    for (final side in _sides) {
      final resized = _fit(source, side);
      for (final quality in _qualities) {
        final bytes = img.encodeJpg(resized, quality: quality);
        if (bytes.length <= kMaxImageBytes) {
          return EncodedImage(
            bytes: bytes,
            width: resized.width,
            height: resized.height,
            preview: _preview(resized),
          );
        }
      }
    }
    throw const ImageCodecException('Image trop lourde, même compressée.');
  }

  /// Scales down so the longest side is at most [side] (never up).
  static img.Image _fit(img.Image image, int side) {
    final longest = image.width > image.height ? image.width : image.height;
    if (longest <= side) return image;
    return image.width >= image.height
        ? img.copyResize(
            image,
            width: side,
            interpolation: img.Interpolation.average,
          )
        : img.copyResize(
            image,
            height: side,
            interpolation: img.Interpolation.average,
          );
  }

  /// JPEG has no transparency: put transparent pictures on white.
  static img.Image _flatten(img.Image image) {
    if (!image.hasAlpha) return image;
    final background = img.Image(width: image.width, height: image.height)
      ..clear(img.ColorRgb8(255, 255, 255));
    return img.compositeImage(background, image);
  }

  /// Tiny, already blurred thumbnail: it reveals nothing of the content.
  static Uint8List _preview(img.Image image) {
    final small = _fit(image, kImagePreviewSide);
    final blurred = img.gaussianBlur(img.Image.from(small), radius: 2);
    return img.encodeJpg(blurred, quality: 50);
  }
}
