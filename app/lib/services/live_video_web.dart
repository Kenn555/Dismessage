import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui' as ui;
import 'dart:ui_web' as ui_web;

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'live_picture.dart';
import 'live_video.dart';

LiveVideoCodecs createLiveVideoCodecs() => const WebLiveVideoCodecs();

/// H.264 as WebCodecs names it: constrained baseline, level 4 (up to
/// 1920 × 1080 at 30 images per second).
const String webH264Codec = 'avc1.42E028';

/// Whether this browser has WebCodecs at all (Firefox before 130 has not).
bool hasWebCodecs(String type) => web.window.has(type);

/// The browser's video decoders (WebCodecs).
class WebLiveVideoCodecs implements LiveVideoCodecs {
  const WebLiveVideoCodecs();

  static Set<String>? _decoders;

  @override
  Future<Set<String>> decoders() {
    final known = _decoders;
    if (known != null) return SynchronousFuture(known);
    return _ask();
  }

  static Future<Set<String>> _ask() async {
    var found = <String>{};
    if (hasWebCodecs('VideoDecoder')) {
      try {
        final support = await web.VideoDecoder.isConfigSupported(
          web.VideoDecoderConfig(codec: webH264Codec, optimizeForLatency: true),
        ).toDart;
        if (support.supported) found = {kLiveCodecH264};
      } catch (_) {
        // None.
      }
    }
    return _decoders = found;
  }

  @override
  LiveVideoDecoder? create(String codec) =>
      codec == kLiveCodecH264 && hasWebCodecs('VideoDecoder')
      ? WebLiveVideoDecoder()
      : null;
}

/// One access unit of [WebH264Encoder], and whether it is a key frame.
typedef WebEncoded = ({Uint8List data, bool key});

/// A WebCodecs H.264 encoder (Annex B, real time): what a canvas shows, one
/// image at a time.
class WebH264Encoder {
  static Set<String>? _codecs;

  /// [kLiveCodecH264] when this browser encodes it.
  static Future<Set<String>> codecs() async {
    final known = _codecs;
    if (known != null) return known;
    var found = <String>{};
    if (hasWebCodecs('VideoEncoder')) {
      try {
        final support = await web.VideoEncoder.isConfigSupported(
          _config(1280, 720, kLiveFullStartKbps),
        ).toDart;
        if (support.supported) found = {kLiveCodecH264};
      } catch (_) {
        // JPEG only.
      }
    }
    return _codecs = found;
  }

  static web.VideoEncoderConfig _config(int width, int height, int kbps) =>
      web.VideoEncoderConfig(
        codec: webH264Codec,
        width: width,
        height: height,
        bitrate: kbps * 1000,
        framerate: kLiveTargetFps,
        latencyMode: 'realtime',
        avc: web.AvcEncoderConfig(format: 'annexb'),
      );

  web.VideoEncoder? _encoder;
  (int, int, int)? _configured;
  Object? _error;
  int _timestamp = 0;
  final Map<int, Completer<WebEncoded?>> _waiting = {};

  /// Encodes what [canvas] shows ([width] × [height], even); null when the
  /// browser gave nothing in time. Throws once the encoder failed.
  Future<WebEncoded?> encode(
    web.HTMLCanvasElement canvas,
    int width,
    int height, {
    required int kbps,
    required bool key,
  }) async {
    final failed = _error;
    if (failed != null) throw StateError('$failed');
    final encoder = _encoder ??= web.VideoEncoder(
      web.VideoEncoderInit(
        output: ((web.EncodedVideoChunk chunk, JSAny? _) {
          final waiting = _waiting.remove(chunk.timestamp);
          if (waiting == null || waiting.isCompleted) return;
          final bytes = Uint8List(chunk.byteLength);
          chunk.copyTo(bytes.toJS);
          waiting.complete((data: bytes, key: chunk.type == 'key'));
        }).toJS,
        error: ((web.DOMException error) {
          _error = error.message;
          for (final waiting in _waiting.values) {
            if (!waiting.isCompleted) waiting.complete(null);
          }
          _waiting.clear();
        }).toJS,
      ),
    );
    // The size changes rarely (a new key frame); the bitrate as the network
    // allows, which the browser applies without a key frame.
    final wanted = (width, height, kbps);
    var asKey = key;
    if (_configured != wanted) {
      if (_configured?.$1 != width || _configured?.$2 != height) asKey = true;
      encoder.configure(_config(width, height, kbps));
      _configured = wanted;
    }
    final timestamp = (_timestamp += 1000000 ~/ kLiveTargetFps);
    final output = _waiting[timestamp] = Completer<WebEncoded?>();
    final frame = web.VideoFrame(
      canvas,
      {'timestamp': timestamp}.jsify()! as JSObject,
    );
    try {
      encoder.encode(frame, web.VideoEncoderEncodeOptions(keyFrame: asKey));
    } finally {
      frame.close();
    }
    final encoded = await output.future.timeout(
      const Duration(seconds: 1),
      onTimeout: () {
        _waiting.remove(timestamp);
        return null;
      },
    );
    final error = _error;
    if (error != null) throw StateError('$error');
    return encoded;
  }

  void close() {
    for (final waiting in _waiting.values) {
      if (!waiting.isCompleted) waiting.complete(null);
    }
    _waiting.clear();
    try {
      final encoder = _encoder;
      if (encoder != null && encoder.state != 'closed') encoder.close();
    } catch (_) {
      // Already closed after an error.
    }
    _encoder = null;
    _configured = null;
  }
}

/// A WebCodecs decoder: each image comes out as a [ui.Image] made from an
/// `ImageBitmap`, without going through Dart's memory.
class WebLiveVideoDecoder implements LiveVideoDecoder {
  web.VideoDecoder? _decoder;
  Object? _error;
  int _timestamp = 0;
  final Map<int, Completer<web.VideoFrame?>> _waiting = {};

  web.VideoDecoder _open() {
    final decoder = web.VideoDecoder(
      web.VideoDecoderInit(
        output: ((web.VideoFrame frame) {
          final waiting = _waiting.remove(frame.timestamp);
          if (waiting == null || waiting.isCompleted) {
            frame.close();
          } else {
            waiting.complete(frame);
          }
        }).toJS,
        error: ((web.DOMException error) {
          _error = error.message;
          for (final waiting in _waiting.values) {
            if (!waiting.isCompleted) waiting.complete(null);
          }
          _waiting.clear();
        }).toJS,
      ),
    );
    decoder.configure(
      web.VideoDecoderConfig(codec: webH264Codec, optimizeForLatency: true),
    );
    return decoder;
  }

  @override
  Future<LivePicture?> decode(
    Uint8List data, {
    required bool key,
    required int rotation,
  }) async {
    final error = _error;
    if (error != null) throw StateError('decoder: $error');
    final decoder = _decoder ??= _open();
    final timestamp = (_timestamp += 33333);
    final output = _waiting[timestamp] = Completer<web.VideoFrame?>();
    decoder.decode(
      web.EncodedVideoChunk(
        web.EncodedVideoChunkInit(
          type: key ? 'key' : 'delta',
          timestamp: timestamp,
          data: data.toJS,
        ),
      ),
    );
    final frame = await output.future.timeout(
      const Duration(milliseconds: 500),
      onTimeout: () {
        _waiting.remove(timestamp);
        return null;
      },
    );
    if (_error != null) {
      frame?.close();
      throw StateError('decoder: $_error');
    }
    if (frame == null) return null;
    try {
      final width = frame.displayWidth, height = frame.displayHeight;
      if (width > kLiveMaxDecodedSide || height > kLiveMaxDecodedSide) {
        throw StateError('too large');
      }
      final bitmap = await web.window
          .createImageBitmap(frame as web.ImageBitmapSource)
          .toDart;
      final image = await ui_web.createImageFromImageBitmap(bitmap);
      return LivePicture.image(image, rotation: rotation);
    } finally {
      frame.close();
    }
  }

  @override
  Future<void> close() async {
    for (final waiting in _waiting.values) {
      if (!waiting.isCompleted) waiting.complete(null);
    }
    _waiting.clear();
    final decoder = _decoder;
    _decoder = null;
    try {
      if (decoder != null && decoder.state != 'closed') decoder.close();
    } catch (_) {
      // Already closed after an error.
    }
  }
}
