import 'dart:typed_data';

import 'live_camera_io.dart'
    if (dart.library.js_interop) 'live_camera_web.dart'
    as platform;

class LiveCameraException implements Exception {
  const LiveCameraException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// This device's camera as a source of small JPEG frames, for the live view.
///
/// Frames are pulled, not pushed: nothing is encoded unless it can leave, so
/// a slow network costs no CPU (Windows: `windows/runner/live_camera.cpp`;
/// Android: `LiveCameraHandler.kt`; web: `getUserMedia`).
abstract class LiveCamera {
  /// Turns the camera on. Throws [LiveCameraException] (none, refused…).
  Future<void> open();

  /// The next image as a JPEG of the given quality (1 to 100), its longest side
  /// close to [side]; null if none is ready yet.
  Future<Uint8List?> nextFrame(int quality, int side);

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
