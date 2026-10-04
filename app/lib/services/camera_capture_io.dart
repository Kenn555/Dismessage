import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'camera_capture.dart';

/// Windows only: Android takes photos through `image_picker`.
CameraCapture? createCameraCapture() =>
    Platform.isWindows ? WindowsCameraCapture() : null;

/// Webcam through `camera_windows`.
class WindowsCameraCapture implements CameraCapture {
  int? _id;
  double _aspectRatio = 4 / 3;

  CameraPlatform get _platform => CameraPlatform.instance;

  @override
  double get aspectRatio => _aspectRatio;

  @override
  Future<void> open() async {
    final List<CameraDescription> cameras;
    try {
      cameras = await _platform.availableCameras();
    } catch (e) {
      throw CameraCaptureException('Webcam inaccessible ($e).');
    }
    if (cameras.isEmpty) {
      throw const CameraCaptureException('Aucune webcam détectée.');
    }
    try {
      final id = _id = await _platform.createCameraWithSettings(
        cameras.first,
        const MediaSettings(
          resolutionPreset: ResolutionPreset.high,
          enableAudio: false,
        ),
      );
      // Listen before initializing: the event can come right away.
      final initialized = _platform.onCameraInitialized(id).first;
      await _platform.initializeCamera(id);
      final event = await initialized;
      if (event.previewWidth > 0 && event.previewHeight > 0) {
        _aspectRatio = event.previewWidth / event.previewHeight;
      }
    } catch (e) {
      await close();
      throw CameraCaptureException(
        'Webcam inaccessible (${e.toString().split('\n').first}).',
      );
    }
  }

  @override
  Widget preview() => _platform.buildPreview(_id!);

  @override
  Future<Uint8List> takePicture() async {
    final file = await _platform.takePicture(_id!);
    final bytes = await file.readAsBytes();
    // camera_windows saves every photo in the user's Pictures folder:
    // messages are never stored, so remove it at once.
    try {
      await File(file.path).delete();
    } on FileSystemException {
      // Already gone or locked: nothing more we can do.
    }
    return bytes;
  }

  @override
  Future<void> close() async {
    final id = _id;
    _id = null;
    if (id != null) await _platform.dispose(id);
  }
}
