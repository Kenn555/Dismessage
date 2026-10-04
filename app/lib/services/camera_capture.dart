import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'camera_capture_io.dart'
    if (dart.library.js_interop) 'camera_capture_web.dart'
    as platform;

class CameraCaptureException implements Exception {
  const CameraCaptureException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A webcam shown live in the app, for platforms where `image_picker`
/// cannot take a photo itself (desktop browsers, Windows).
abstract class CameraCapture {
  /// Asks for the camera and starts the preview. Throws
  /// [CameraCaptureException] (no camera, access refused…).
  Future<void> open();

  /// Width / height of the preview, once open.
  double get aspectRatio;

  Widget preview();

  /// A JPEG of the current frame. Nothing is left on disk.
  Future<Uint8List> takePicture();

  Future<void> close();
}

/// The live camera of this platform, or null when `image_picker` handles
/// photos itself (Android, phone browsers) or there is none.
CameraCapture? platformCameraCapture() => platform.createCameraCapture();
