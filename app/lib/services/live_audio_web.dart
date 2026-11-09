import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:web/web.dart' as web;

import 'live_audio.dart';

LiveMicrophone? createLiveMicrophone(String? deviceId) =>
    PluginLiveMicrophone(deviceId);

LiveSpeaker? createLiveSpeaker() => WebLiveSpeaker();

/// Plays the chunks one after the other on an `AudioContext`, which resamples
/// them to the device's rate.
class WebLiveSpeaker implements LiveSpeaker {
  web.AudioContext? _context;

  /// When the last scheduled chunk ends, in the context's seconds.
  double _next = 0;

  @override
  Future<void> open() async {
    try {
      final context = _context = web.AudioContext();
      // The request to see the camera was a tap: the page may play sound.
      if (context.state != 'running') await context.resume().toDart;
    } catch (e) {
      throw LiveAudioException('Son indisponible ($e).');
    }
  }

  @override
  void play(Int16List samples) {
    final context = _context;
    if (context == null || samples.isEmpty) return;
    final buffer = context.createBuffer(
      1,
      samples.length,
      kLiveAudioSampleRate,
    );
    final floats = Float32List(samples.length);
    for (var i = 0; i < samples.length; i++) {
      floats[i] = samples[i] / 32768;
    }
    buffer.copyToChannel(floats.toJS, 0);
    final source = context.createBufferSource()..buffer = buffer;
    source.connect(context.destination);
    _next = math.max(_next, context.currentTime);
    source.start(_next);
    _next += buffer.duration;
  }

  @override
  Future<void> close() async {
    final context = _context;
    _context = null;
    if (context == null) return;
    try {
      await context.close().toDart;
    } catch (_) {
      // Already closed.
    }
  }
}
