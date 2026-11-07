import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'live_camera.dart';

LiveCamera? createLiveCamera(String? deviceId) => WebLiveCamera(deviceId);

/// `getUserMedia`, drawn on a canvas that the browser encodes.
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
  Future<Uint8List?> nextFrame(int quality, int side) async {
    // Native cameras give the pace; here the canvas would always have one.
    final wait = 1000 ~/ kLiveTargetFps - _sinceLast.elapsedMilliseconds;
    if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
    _sinceLast
      ..reset()
      ..start();
    final video = _video, canvas = _canvas;
    if (video == null || canvas == null || video.videoWidth == 0) return null;
    final scale = math.min(
      1.0,
      side / math.max(video.videoWidth, video.videoHeight),
    );
    final width = (video.videoWidth * scale).round();
    final height = (video.videoHeight * scale).round();
    if (canvas.width != width) canvas.width = width;
    if (canvas.height != height) canvas.height = height;
    (canvas.getContext('2d')! as web.CanvasRenderingContext2D).drawImage(
      video,
      0,
      0,
      width,
      height,
    );
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
  }
}
