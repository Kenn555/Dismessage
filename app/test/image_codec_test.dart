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
