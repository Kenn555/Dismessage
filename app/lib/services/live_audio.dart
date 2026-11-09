import 'dart:async';
import 'dart:typed_data';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:record_platform_interface/record_platform_interface.dart';

import 'live_audio_io.dart'
    if (dart.library.js_interop) 'live_audio_web.dart'
    as platform;

class LiveAudioException implements Exception {
  const LiveAudioException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The microphone, for the sound of a live view: 16-bit little-endian mono
/// PCM at [kLiveAudioSampleRate], in chunks of any size.
abstract class LiveMicrophone {
  /// Turns it on; [onPcm] then gets the sound as it comes. Throws
  /// [LiveAudioException] (none, refused…).
  Future<void> open(void Function(Uint8List pcm) onPcm);

  /// Turns it off.
  Future<void> close();
}

/// Plays the peer's sound: each chunk after the previous one, at
/// [kLiveAudioSampleRate] (the playout buffer is [LiveAudioJitter]'s).
abstract class LiveSpeaker {
  /// Throws [LiveAudioException] when nothing can be played.
  Future<void> open();

  void play(Int16List samples);

  Future<void> close();
}

/// The microphone of this platform ([deviceId] if given and still there), or
/// null when it has none we can drive live.
LiveMicrophone? platformLiveMicrophone({String? deviceId}) =>
    platform.createLiveMicrophone(deviceId);

/// What plays the sound on this platform, or null.
LiveSpeaker? platformLiveSpeaker() => platform.createLiveSpeaker();

const _denied = LiveAudioException(
  'Accès au micro refusé : la caméra est partagée sans le son.',
);

/// Web and Windows: the `record` implementations, as a stream of PCM.
class PluginLiveMicrophone implements LiveMicrophone {
  PluginLiveMicrophone(this._deviceId);

  final String? _deviceId;
  static int _count = 0;
  final _id = 'dismessage-live-mic-${_count++}';
  bool _created = false;
  StreamSubscription<Uint8List>? _sound;

  RecordPlatform get _platform => RecordPlatform.instance;

  @override
  Future<void> open(void Function(Uint8List pcm) onPcm) async {
    try {
      await _platform.create(_id);
      _created = true;
      if (!await _platform.hasPermission(_id)) throw _denied;
      final stream = await _platform.startStream(
        _id,
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: kLiveAudioSampleRate,
          numChannels: 1,
          device: await _chosenDevice(),
          // Browsers: the peer's sound from the speakers is not sent back.
          echoCancel: true,
          noiseSuppress: true,
          autoGain: true,
          // About one packet ([kLiveAudioPacketMs]) at a time.
          streamBufferSize: 1024,
        ),
      );
      _sound = stream.listen(onPcm, onError: (Object _) {});
    } on LiveAudioException {
      await close();
      rethrow;
    } catch (e) {
      await close();
      throw LiveAudioException(
        'Micro indisponible (${e.toString().split('\n').first}) : la caméra '
        'est partagée sans le son.',
      );
    }
  }

  /// The microphone chosen in the settings; unplugged since: the default.
  Future<InputDevice?> _chosenDevice() async {
    final wanted = _deviceId;
    if (wanted == null) return null;
    for (final device in await _platform.listInputDevices(_id)) {
      if (device.id == wanted) return device;
    }
    return null;
  }

  @override
  Future<void> close() async {
    await _sound?.cancel();
    _sound = null;
    if (!_created) return;
    _created = false;
    try {
      await _platform.cancel(_id);
    } catch (_) {
      // Not started.
    }
    try {
      await _platform.dispose(_id);
    } catch (_) {
      // Already gone.
    }
  }
}

/// Denied microphone, for the platforms that only give a yes or a no.
const LiveAudioException liveMicrophoneDenied = _denied;
