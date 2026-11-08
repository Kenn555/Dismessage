import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'live_camera.dart';
import 'live_video_web.dart';

LiveCamera? createLiveCamera(String? deviceId) => WebLiveCamera(deviceId);

/// `getUserMedia`, drawn on a canvas that the browser encodes: as H.264 with
/// WebCodecs when both sides can, else as JPEG.
class WebLiveCamera implements LiveCamera {
  WebLiveCamera(this._deviceId);

  final String? _deviceId;
  web.MediaStream? _stream;
  web.HTMLVideoElement? _video;
  web.HTMLCanvasElement? _canvas;
  final _sinceLast = Stopwatch()..start();

  @override
  Future<void> open() async {
    final web.MediaStream stream;
    try {
      stream = await web.window.navigator.mediaDevices
          .getUserMedia(
            web.MediaStreamConstraints(
              // Only what is sent: a lighter load on the camera and the CPU.
              video: {
                if (_deviceId case final id?)
                  'deviceId': {'ideal': id}
                else
                  'facingMode': 'user',
                'width': {'ideal': 320},
                'height': {'ideal': 240},
                'frameRate': {'ideal': kLiveTargetFps},
              }.jsify()!,
              audio: false.toJS,
            ),
          )
          .toDart;
    } catch (e) {
      throw LiveCameraException(_describe(e));
    }
    _stream = stream;
    final video = _video = web.HTMLVideoElement()
      ..autoplay = true
      ..muted = true
      ..playsInline = true
      ..srcObject = stream;
    _canvas = web.HTMLCanvasElement();
    try {
      await video.play().toDart;
    } catch (e) {
      await close();
      throw LiveCameraException(_describe(e));
    }
  }

  static String _describe(Object error) {
    final text = error.toString();
    if (text.contains('NotAllowed')) {
      return "Autorisez l'accès à la caméra dans le navigateur.";
    }
    if (text.contains('NotFound') || text.contains('Overconstrained')) {
      return 'Aucune caméra détectée.';
    }
    if (text.contains('NotReadable')) {
      return 'La caméra est utilisée par une autre application.';
    }
    return 'Caméra inaccessible (${text.split('\n').first}).';
  }

  @override
  Future<void> setCaptureSide(int side) async {
    final tracks = _stream?.getVideoTracks().toDart ?? <web.MediaStreamTrack>[];
    for (final track in tracks) {
      try {
        await track
            .applyConstraints(
              {
                    'width': {'ideal': side},
                    'frameRate': {'ideal': kLiveTargetFps},
                  }.jsify()!
                  as web.MediaTrackConstraints,
            )
            .toDart;
      } catch (_) {
        // The frames stay at their size.
      }
    }
  }

  @override
  Future<Set<String>> encoders() => WebH264Encoder.codecs();

  WebH264Encoder? _encoder;
  web.HTMLCanvasElement? _previewCanvas;

  @override
  Future<LiveCameraFrame?> nextFrame(LiveFrameRequest request) async {
    // Native cameras give the pace; here the canvas would always have one.
    final wait = 1000 ~/ kLiveTargetFps - _sinceLast.elapsedMilliseconds;
    if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
    _sinceLast
      ..reset()
      ..start();
    final video = _video, canvas = _canvas;
    if (video == null || canvas == null || video.videoWidth == 0) return null;
    final codec = request.codec;
    // Video wants even sizes (colours are kept for 2 × 2 pixels).
    final (width, height) = fitLiveSize(
      video.videoWidth,
      video.videoHeight,
      request.side,
      even: codec != null,
    );
    if (canvas.width != width) canvas.width = width;
    if (canvas.height != height) canvas.height = height;
    (canvas.getContext('2d')! as web.CanvasRenderingContext2D).drawImage(
      video,
      0,
      0,
      width,
      height,
    );
    if (codec == null) {
      final jpeg = await canvasJpeg(canvas, request.quality);
      return jpeg == null ? null : LiveCameraFrame(jpeg);
    }
    final encoder = _encoder ??= WebH264Encoder();
    final (WebEncoded? encoded, Object? error) = await encoder
        .encode(canvas, width, height, kbps: request.kbps, key: request.key)
        .then<(WebEncoded?, Object?)>(
          (frame) => (frame, null),
          onError: (Object e) => (null, e),
        );
    if (error != null) {
      throw LiveCameraException('Encodage vidéo impossible ($error).');
    }
    if (encoded == null) return null;
    Uint8List? preview;
    if (request.preview) {
      final small = _previewCanvas ??= web.HTMLCanvasElement();
      final (w, h) = fitLiveSize(width, height, 160, even: false);
      small
        ..width = w
        ..height = h;
      (small.getContext('2d')! as web.CanvasRenderingContext2D).drawImage(
        canvas,
        0,
        0,
        w,
        h,
      );
      preview = await canvasJpeg(small, kLiveQualityStart);
    }
    return LiveCameraFrame(encoded.data, key: encoded.key, preview: preview);
  }

  @override
  Future<void> close() async {
    for (final track
        in _stream?.getTracks().toDart ?? <web.MediaStreamTrack>[]) {
      track.stop();
    }
    _stream = null;
    _video?.srcObject = null;
    _video = null;
    _canvas = null;
    _previewCanvas = null;
    _encoder?.close();
    _encoder = null;
  }
}

/// The size of an image of [width] × [height] whose longest side is at most
/// [side]; [even] for video.
(int, int) fitLiveSize(int width, int height, int side, {required bool even}) {
  final scale = math.min(1.0, side / math.max(width, height));
  var w = (width * scale).round(), h = (height * scale).round();
  if (even) {
    w = math.max(2, w & ~1);
    h = math.max(2, h & ~1);
  }
  return (math.max(1, w), math.max(1, h));
}

/// What [canvas] shows, as a JPEG.
Future<Uint8List?> canvasJpeg(web.HTMLCanvasElement canvas, int quality) async {
  final done = Completer<web.Blob?>();
  canvas.toBlob(
    ((web.Blob? blob) => done.complete(blob)).toJS,
    'image/jpeg',
    (quality / 100).toJS,
  );
  final blob = await done.future;
  if (blob == null) return null;
  return (await blob.arrayBuffer().toDart).toDart.asUint8List();
}
