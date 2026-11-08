import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// One image of a live view: a decoded image, or a platform texture that a
/// native video decoder draws into (Android), turned by [rotation] degrees
/// clockwise to be upright.
@immutable
class LivePicture {
  LivePicture.image(ui.Image this.image, {this.rotation = 0})
    : texture = null,
      width = image.width,
      height = image.height;

  const LivePicture.texture(
    int this.texture, {
    required this.width,
    required this.height,
    this.rotation = 0,
  }) : image = null;

  final ui.Image? image;
  final int? texture;

  /// Size before the rotation.
  final int width;
  final int height;

  /// 0, 90, 180 or 270.
  final int rotation;

  int get quarterTurns => (rotation ~/ 90) % 4;

  /// Width / height as shown.
  double get aspectRatio {
    if (width == 0 || height == 0) return 4 / 3;
    return quarterTurns.isOdd ? height / width : width / height;
  }

  /// Frees the image; a texture belongs to its decoder.
  void dispose() => image?.dispose();

  /// Texture pictures are equal when they show the same: the view does not
  /// rebuild for each frame the texture receives.
  @override
  bool operator ==(Object other) =>
      other is LivePicture &&
      identical(image, other.image) &&
      texture == other.texture &&
      width == other.width &&
      height == other.height &&
      rotation == other.rotation;

  @override
  int get hashCode => Object.hash(image, texture, width, height, rotation);
}
