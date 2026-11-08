import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';

import 'live_camera_io.dart'
    if (dart.library.js_interop) 'live_camera_web.dart'
    as platform;

class LiveCameraException implements Exception {
  const LiveCameraException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What the next frame of [LiveCamera.nextFrame] should be.
@immutable
class LiveFrameRequest {
  const LiveFrameRequest({
    required this.side,
    this.quality = kLiveQualityStart,
    this.codec,
    this.kbps = kLiveStartKbps,
    this.key = false,
    this.preview = false,
  });

  /// Longest side, about.
  final int side;

  /// JPEG quality (1 to 100), when [codec] is null.
  final int quality;

  /// A video codec ([kLiveCodecH264]), or null for JPEG.
  final String? codec;

  /// Video bitrate, in kbit/s.
  final int kbps;

  /// Video: a key frame, which the viewer can start decoding from.
  final bool key;

  /// Video: also a small JPEG of the same image ([LiveCameraFrame.preview]).
  final bool preview;
}

/// One frame of [LiveCamera.nextFrame].
class LiveCameraFrame {
  const LiveCameraFrame(
    this.data, {
    this.key = false,
    this.rotation = 0,
    this.preview,
  });

  /// A JPEG, or a video access unit (Annex B for H.264).
  final Uint8List data;

  /// Video: a key frame.
  final bool key;

  /// Clockwise degrees to turn the image by to show it upright (video and
  /// [preview]; a JPEG is already upright).
  final int rotation;

  /// A small JPEG of the same image, when asked for: my own thumbnail.
  final Uint8List? preview;
}

/// This device's camera as a source of frames for the live view: JPEG, or
/// video when both sides can ([encoders]).
///
/// Frames are pulled, not pushed: nothing is encoded unless it can leave, so
/// a slow network costs no CPU (Windows: `windows/runner/live_camera.cpp`;
/// Android: `LiveCameraHandler.kt`; web: `getUserMedia` and WebCodecs). A
/// video encoder only sees the images that leave: skipping one before it is
/// encoded never breaks the stream.
abstract class LiveCamera {
  /// Turns the camera on. Throws [LiveCameraException] (none, refused…).
  Future<void> open();

  /// Video codecs this camera can encode into, once open; empty for JPEG
  /// only.
  Future<Set<String>> encoders();

  /// The next image, as asked; null if none is ready yet.
  Future<LiveCameraFrame?> nextFrame(LiveFrameRequest request);

  /// Captures at about [side] pixels (more in full screen). The camera may
  /// take a moment to change.
  Future<void> setCaptureSide(int side);

  /// Turns the camera off.
  Future<void> close();
}

/// The camera of this platform ([deviceId] if given and still there), or null
/// if it has none we can drive.
LiveCamera? platformLiveCamera({String? deviceId}) =>
    platform.createLiveCamera(deviceId);
