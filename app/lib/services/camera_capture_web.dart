import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'camera_capture.dart';

/// Desktop browsers ignore the "camera" hint of a file input: show the
/// webcam ourselves. Phone browsers open their own camera app through
/// `image_picker`, which is better there.
CameraCapture? createCameraCapture() {
  final phone =
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  return phone ? null : WebCameraCapture();
}

/// Webcam through `getUserMedia`, previewed in a `<video>` element.
class WebCameraCapture implements CameraCapture {
  static int _count = 0;
  final _viewType = 'dismessage-camera-${_count++}';
  web.MediaStream? _stream;
  web.HTMLVideoElement? _video;
  double _aspectRatio = 4 / 3;

  @override
  double get aspectRatio => _aspectRatio;

  @override
  Future<void> open() async {
    final web.MediaStream stream;
    try {
      stream = await web.window.navigator.mediaDevices
          .getUserMedia(
            web.MediaStreamConstraints(
              video: {
                'facingMode': 'user',
                'width': {'ideal': 1280},
                'height': {'ideal': 720},
              }.jsify()!,
              audio: false.toJS,
            ),
          )
          .toDart;
    } catch (e) {
      throw CameraCaptureException(_describe(e));
    }
    _stream = stream;
    final video = _video = web.HTMLVideoElement()
      ..autoplay = true
      ..muted = true
      ..playsInline = true
      ..srcObject = stream;
    video.style
      ..width = '100%'
      ..height = '100%'
      ..objectFit = 'cover'
      ..transform = 'scaleX(-1)';
    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int _) => video,
    );
    final ready = Completer<void>();
    video.onLoadedMetadata.first.then((_) => ready.complete());
    await video.play().toDart;
    if (video.videoWidth == 0) {
      await ready.future.timeout(const Duration(seconds: 10));
    }
    if (video.videoWidth > 0 && video.videoHeight > 0) {
      _aspectRatio = video.videoWidth / video.videoHeight;
    }
  }

  static String _describe(Object error) {
    final text = error.toString();
    if (text.contains('NotAllowed')) {
      return "Autorisez l'accès à la caméra dans le navigateur.";
    }
    if (text.contains('NotFound') || text.contains('Overconstrained')) {
      return 'Aucune webcam détectée.';
    }
    if (text.contains('NotReadable')) {
      return 'La webcam est utilisée par une autre application.';
    }
    return 'Webcam inaccessible (${text.split('\n').first}).';
  }

  @override
  Widget preview() => HtmlElementView(viewType: _viewType);

  @override
  Future<Uint8List> takePicture() async {
    final video = _video!;
    final canvas = web.HTMLCanvasElement()
      ..width = video.videoWidth
      ..height = video.videoHeight;
    final context = canvas.getContext('2d')! as web.CanvasRenderingContext2D;
    // The preview is mirrored, the photo is not (text stays readable).
    context.drawImage(video, 0, 0);
    final done = Completer<web.Blob?>();
    canvas.toBlob(
      ((web.Blob? blob) => done.complete(blob)).toJS,
      'image/jpeg',
      0.92.toJS,
    );
    final blob = await done.future;
    if (blob == null) {
      throw const CameraCaptureException('La photo n’a pas pu être prise.');
    }
    final buffer = await blob.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  }

  @override
  Future<void> close() async {
    for (final track
        in _stream?.getTracks().toDart ?? <web.MediaStreamTrack>[]) {
      track.stop();
    }
    _stream = null;
    _video?.srcObject = null;
  }
}
