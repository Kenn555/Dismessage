import 'package:dismessage/services/voice_recorder.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record_platform_interface/record_platform_interface.dart';

void main() {
  final aac = voiceFormats.firstWhere((f) => f.$1 == AudioEncoder.aacLc);
  final wav = voiceFormats.firstWhere((f) => f.$1 == AudioEncoder.wav);

  test('Windows records AAC as its encoder accepts it', () {
    // Media Foundation refuses AAC under 44.1 kHz or 96 kbit/s.
    final (rate, bits) = recordSettings(aac, windows: true);
    expect(rate, anyOf(44100, 48000));
    expect(bits, isIn([96000, 128000, 160000, 192000]));
  });

  test('elsewhere, compact AAC', () {
    expect(recordSettings(aac, windows: false), (16000, kVoiceBitRate));
    expect(recordSettings(wav, windows: true), (8000, wav.$4));
  });

  test('a longer message only where the bit rate allows it', () {
    final (_, windowsBits) = recordSettings(aac, windows: true);
    final windows = VoiceRecorder.maxDurationFor(windowsBits);
    expect(windows.inSeconds, greaterThanOrEqualTo(30));
    expect(windowsBits * windows.inSeconds / 8, lessThan(kMaxVoiceBytes));
    expect(
      VoiceRecorder.maxDurationFor(kVoiceBitRate).inSeconds,
      kMaxVoiceSeconds,
    );
  });
}
