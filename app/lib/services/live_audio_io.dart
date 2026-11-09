import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/services.dart';

import 'live_audio.dart';

LiveMicrophone? createLiveMicrophone(String? deviceId) {
  if (Platform.isWindows) return PluginLiveMicrophone(deviceId);
  if (Platform.isAndroid) return AndroidLiveMicrophone(deviceId);
  return null;
}

LiveSpeaker? createLiveSpeaker() {
  if (Platform.isWindows) {
    return ChannelLiveSpeaker(const MethodChannel('dismessage/audio'));
  }
  if (Platform.isAndroid) {
    return ChannelLiveSpeaker(const MethodChannel('dismessage/voice'));
  }
  return null;
}

/// Android: AudioRecord through our own channel (`VoiceHandler.kt`, with the
/// echo canceller of voice calls), read every packet or so.
class AndroidLiveMicrophone implements LiveMicrophone {
  AndroidLiveMicrophone(this._deviceId);

  static const _channel = MethodChannel('dismessage/voice');
  final String? _deviceId;
  Timer? _reader;
  bool _reading = false;

  @override
  Future<void> open(void Function(Uint8List pcm) onPcm) async {
    final granted = await _channel.invokeMethod<bool>('hasPermission', {
      'request': true,
    });
    if (granted != true) throw liveMicrophoneDenied;
    try {
      await _channel.invokeMethod<void>('micOpen', {
        'rate': kLiveAudioSampleRate,
        'device': ?_deviceId,
      });
    } on PlatformException catch (e) {
      throw LiveAudioException(
        'Micro indisponible (${e.message ?? e.code}) : la caméra est '
        'partagée sans le son.',
      );
    }
    _reader = Timer.periodic(
      const Duration(milliseconds: kLiveAudioPacketMs),
      (_) => _read(onPcm),
    );
  }

  Future<void> _read(void Function(Uint8List pcm) onPcm) async {
    if (_reading) return;
    _reading = true;
    try {
      final pcm = await _channel.invokeMethod<Uint8List>('micRead');
      if (_reader != null && pcm != null && pcm.isNotEmpty) onPcm(pcm);
    } on PlatformException {
      // Stopped meanwhile.
    } finally {
      _reading = false;
    }
  }

  @override
  Future<void> close() async {
    _reader?.cancel();
    _reader = null;
    try {
      await _channel.invokeMethod<void>('micClose');
    } on PlatformException {
      // Already off.
    } on MissingPluginException {
      // Never opened.
    }
  }
}

/// The runner plays PCM chunks one after the other (Windows: waveOut,
/// `windows/runner/live_audio.cpp`; Android: AudioTrack, `LiveAudio.kt`).
class ChannelLiveSpeaker implements LiveSpeaker {
  ChannelLiveSpeaker(this._channel);

  final MethodChannel _channel;
  int? _id;

  @override
  Future<void> open() async {
    try {
      _id = await _channel.invokeMethod<int>('speakerOpen', {
        'rate': kLiveAudioSampleRate,
      });
    } on PlatformException catch (e) {
      throw LiveAudioException('Son indisponible (${e.message ?? e.code}).');
    } on MissingPluginException {
      throw const LiveAudioException('Son indisponible.');
    }
  }

  @override
  void play(Int16List samples) {
    final id = _id;
    if (id == null) return;
    _channel
        .invokeMethod<void>('speakerPlay', {
          'id': id,
          'pcm': samples.buffer.asUint8List(
            samples.offsetInBytes,
            samples.lengthInBytes,
          ),
        })
        .catchError((Object _) {});
  }

  @override
  Future<void> close() async {
    final id = _id;
    _id = null;
    if (id == null) return;
    try {
      await _channel.invokeMethod<void>('speakerClose', {'id': id});
    } on PlatformException {
      // Already closed.
    }
  }
}
