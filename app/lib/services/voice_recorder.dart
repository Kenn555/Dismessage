import 'dart:async';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record_platform_interface/record_platform_interface.dart';

import 'chat_session.dart';
import 'voice_file.dart';

class VoiceRecorderException implements Exception {
  const VoiceRecorderException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Records one voice message at a time from the microphone.
abstract class VoiceRecorder {
  /// Starts recording. Throws [VoiceRecorderException] (no microphone,
  /// permission denied…).
  Future<void> start();

  /// Stops and returns the recording, or null if nothing was captured.
  Future<RecordedVoice?> stop();

  /// Stops and throws the recording away.
  Future<void> cancel();

  /// Longest recording, after which the UI stops (and sends) it.
  Duration get maxDuration;

  Future<void> dispose();

  /// Longest recording that fits in [kMaxVoiceBytes] at [bitRate], with a
  /// 5 % margin for the container.
  static Duration maxDurationFor(int bitRate) {
    final seconds = kMaxVoiceBytes * 8 * 0.95 ~/ bitRate;
    return Duration(seconds: seconds.clamp(1, kMaxVoiceSeconds));
  }
}

/// The recorder of the current platform.
VoiceRecorder platformVoiceRecorder() =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android
    ? AndroidVoiceRecorder()
    : PluginVoiceRecorder();

const _permissionDenied = VoiceRecorderException(
  "Autorisez l'accès au micro pour envoyer un message vocal.",
);

/// Android: MediaRecorder through our own channel (see `VoiceHandler.kt`),
/// so the build needs no extra Gradle download. Always AAC in MP4.
class AndroidVoiceRecorder implements VoiceRecorder {
  static const channel = MethodChannel('dismessage/voice');
  final _clock = Stopwatch();

  @override
  Duration get maxDuration => VoiceRecorder.maxDurationFor(kVoiceBitRate);

  @override
  Future<void> start() async {
    final granted = await channel.invokeMethod<bool>('hasPermission', {
      'request': true,
    });
    if (granted != true) throw _permissionDenied;
    try {
      await channel.invokeMethod<void>('start', {
        'path': await newVoicePath('m4a'),
        'bitRate': kVoiceBitRate,
      });
    } on PlatformException catch (e) {
      throw VoiceRecorderException('Micro indisponible : ${e.message}');
    }
    _clock
      ..reset()
      ..start();
  }

  @override
  Future<RecordedVoice?> stop() async {
    _clock.stop();
    final path = await channel.invokeMethod<String>('stop');
    if (path == null) return null;
    final file = await readVoiceFile(path);
    if (file == null || file.bytes.isEmpty) return null;
    return RecordedVoice(
      bytes: file.bytes,
      mime: 'audio/mp4',
      duration: _clock.elapsed,
    );
  }

  @override
  Future<void> cancel() async {
    _clock.stop();
    await channel.invokeMethod<void>('cancel');
  }

  @override
  Future<void> dispose() async {}
}

/// Encoders tried in order: compact AAC first, Opus where AAC cannot be
/// recorded (some browsers), then WAV as a last resort.
const _formats = <(AudioEncoder, String, String, int)>[
  (AudioEncoder.aacLc, 'audio/mp4', 'm4a', kVoiceBitRate),
  (AudioEncoder.opus, 'audio/webm', 'webm', kVoiceBitRate),
  // 8 kHz, 16 bits mono: 128 kbit/s, so only a short message fits.
  (AudioEncoder.wav, 'audio/wav', 'wav', 128000),
];

/// Web and Windows: the `record` implementations, used directly.
class PluginVoiceRecorder implements VoiceRecorder {
  static int _count = 0;
  final _id = 'dismessage-recorder-${_count++}';
  final _clock = Stopwatch();
  bool _created = false;
  (AudioEncoder, String, String, int)? _format;

  RecordPlatform get _platform => RecordPlatform.instance;

  @override
  Duration get maxDuration =>
      VoiceRecorder.maxDurationFor(_format?.$4 ?? kVoiceBitRate);

  @override
  Future<void> start() async {
    if (!_created) {
      await _platform.create(_id);
      _created = true;
    }
    if (!await _platform.hasPermission(_id)) throw _permissionDenied;
    final format = await _pickFormat();
    if (format == null) {
      throw const VoiceRecorderException(
        "L'enregistrement audio n'est pas pris en charge ici.",
      );
    }
    _format = format;
    final (encoder, _, extension, bitRate) = format;
    try {
      await _platform.start(
        _id,
        RecordConfig(
          encoder: encoder,
          bitRate: bitRate,
          sampleRate: encoder == AudioEncoder.wav ? 8000 : 16000,
          numChannels: 1,
        ),
        path: await newVoicePath(extension),
      );
    } catch (e) {
      throw VoiceRecorderException('Micro indisponible : $e');
    }
    _clock
      ..reset()
      ..start();
  }

  Future<(AudioEncoder, String, String, int)?> _pickFormat() async {
    for (final format in _formats) {
      if (await _platform.isEncoderSupported(_id, format.$1)) return format;
    }
    return null;
  }

  @override
  Future<RecordedVoice?> stop() async {
    _clock.stop();
    final path = await _platform.stop(_id);
    final format = _format;
    if (path == null || format == null) return null;
    final file = await readVoiceFile(path);
    if (file == null || file.bytes.isEmpty) return null;
    return RecordedVoice(
      bytes: file.bytes,
      // The browser knows the real container (e.g. Opus in Ogg or WebM).
      mime: _cleanMime(file.mime) ?? format.$2,
      duration: _clock.elapsed,
    );
  }

  @override
  Future<void> cancel() async {
    _clock.stop();
    await _platform.cancel(_id);
  }

  @override
  Future<void> dispose() async {
    if (_created) await _platform.dispose(_id);
  }

  static String? _cleanMime(String? mime) {
    final value = mime?.toLowerCase().replaceAll(' ', '');
    if (value == null || !value.startsWith('audio/')) return null;
    return value.length <= 80 ? value : null;
  }
}

/// Formats a voice duration as "0:07" or "1:42".
String formatVoiceDuration(Duration d) {
  final seconds = d.inSeconds;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}
