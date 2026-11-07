import 'dart:typed_data';

import 'package:dismessage/services/image_codec.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// A noisy picture compresses badly: a good stress test for the size limit.
Uint8List noisyPng(int width, int height, {bool alpha = false}) {
  final picture = img.Image(
    width: width,
    height: height,
    numChannels: alpha ? 4 : 3,
  );
  var seed = 7;
  for (final pixel in picture) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    pixel
      ..r = seed & 0xff
      ..g = (seed >> 8) & 0xff
      ..b = (seed >> 16) & 0xff;
    if (alpha) pixel.a = (seed >> 4) & 0xff;
  }
  return img.encodePng(picture);
}

void main() {
  test('large photo is resized, compressed under the limit, as JPEG', () {
    final result = ImageCodec.encode(noisyPng(3000, 2000));
    expect(result.width, kMaxImageSide);
    expect(result.height, closeTo(853, 1));
    expect(result.bytes.length, lessThanOrEqualTo(kMaxImageBytes));
    // JPEG magic number.
    expect(result.bytes.sublist(0, 2), [0xFF, 0xD8]);
  });

  test('portrait keeps its orientation and ratio', () {
    final result = ImageCodec.encode(noisyPng(600, 1600));
    expect(result.height, lessThanOrEqualTo(kMaxImageSide));
    expect(result.width / result.height, closeTo(600 / 1600, 0.01));
  });

  test('small images are never upscaled', () {
    final result = ImageCodec.encode(noisyPng(200, 100));
    expect((result.width, result.height), (200, 100));
  });

  test('preview is tiny and fits in an offer frame', () {
    final result = ImageCodec.encode(noisyPng(1200, 900));
    final preview = img.decodeJpg(result.preview)!;
    expect(preview.width, kImagePreviewSide);
    final base64Length = (result.preview.length + 2) ~/ 3 * 4;
    expect(base64Length, lessThan(kMaxImagePreviewLength));
  });

  test('transparent images are accepted (flattened)', () {
    final result = ImageCodec.encode(noisyPng(300, 300, alpha: true));
    expect(result.bytes.sublist(0, 2), [0xFF, 0xD8]);
  });

  test('a pasted Windows bitmap with an unused alpha stays visible', () {
    // What the runner builds from CF_DIB: 32 bits per pixel, BI_RGB, alpha
    // bytes left at 0 by the screenshot.
    const width = 4, height = 4;
    final bmp = ByteData(14 + 40 + width * height * 4);
    bmp
      ..setUint8(0, 0x42)
      ..setUint8(1, 0x4D)
      ..setUint32(2, bmp.lengthInBytes, Endian.little)
      ..setUint32(10, 14 + 40, Endian.little)
      ..setUint32(14, 40, Endian.little)
      ..setInt32(18, width, Endian.little)
      ..setInt32(22, height, Endian.little)
      ..setUint16(26, 1, Endian.little)
      ..setUint16(28, 32, Endian.little);
    for (var i = 0; i < width * height; i++) {
      // Bytes blue 0xFF, green 0xC8, red 0, alpha 0.
      bmp.setUint32(54 + i * 4, 0x0000C8FF, Endian.little);
    }
    final result = ImageCodec.encode(bmp.buffer.asUint8List());
    final pixel = img.decodeJpg(result.bytes)!.getPixel(2, 2);
    // Sky blue, not the white of a "fully transparent" picture.
    expect(pixel.r, closeTo(0x00, 12));
    expect(pixel.g, closeTo(0xC8, 12));
    expect(pixel.b, closeTo(0xFF, 12));
  });

  test('a picture whose alpha is 0 everywhere is read as opaque', () {
    final picture = img.Image(width: 4, height: 4, numChannels: 4);
    for (final pixel in picture) {
      pixel
        ..r = 0
        ..g = 0xC8
        ..b = 0xFF
        ..a = 0;
    }
    final result = ImageCodec.encode(img.encodePng(picture));
    final pixel = img.decodeJpg(result.bytes)!.getPixel(2, 2);
    expect(pixel.r, closeTo(0x00, 12));
    expect(pixel.b, closeTo(0xFF, 12));
  });

  test('metadata is dropped by re-encoding', () {
    final picture = img.Image(width: 50, height: 50)
      ..exif.imageIfd['Make'] = 'SecretPhone';
    final input = img.encodeJpg(picture);
    expect(String.fromCharCodes(input), contains('SecretPhone'));
    final result = ImageCodec.encode(input);
    expect(String.fromCharCodes(result.bytes), isNot(contains('SecretPhone')));
  });

  test('garbage is refused with a French message', () {
    expect(
      () => ImageCodec.encode(Uint8List.fromList([1, 2, 3, 4])),
      throwsA(
        isA<ImageCodecException>().having(
          (e) => e.message,
          'message',
          contains('non pris en charge'),
        ),
      ),
    );
  });
}
