import 'dart:math';
import 'dart:typed_data';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:test/test.dart';

/// 16-bit little-endian PCM of [samples].
Uint8List _pcm(Int16List samples) => samples.buffer.asUint8List(
  samples.offsetInBytes,
  samples.lengthInBytes,
);

/// A voice-like tone: [ms] of two sines.
Int16List _tone(int ms, {double phase = 0}) {
  final count = kLiveAudioSampleRate * ms ~/ 1000;
  return Int16List.fromList([
    for (var i = 0; i < count; i++)
      (9000 * sin(2 * pi * 220 * i / kLiveAudioSampleRate + phase) +
              4000 * sin(2 * pi * 1250 * i / kLiveAudioSampleRate))
          .round(),
  ]);
}

/// Signal to noise ratio of [decoded] against [original], in dB.
double _snr(Int16List original, Int16List decoded) {
  var signal = 0.0;
  var noise = 0.0;
  for (var i = 0; i < original.length; i++) {
    signal += original[i] * original[i].toDouble();
    final error = original[i] - decoded[i];
    noise += error * error.toDouble();
  }
  return 10 * log(signal / max(noise, 1)) / ln10;
}

void main() {
  group('ImaAdpcm', () {
    test('a packet is a quarter of the PCM, and sounds like it', () {
      final tone = _tone(kLiveAudioPacketMs);
      final packet = ImaAdpcmEncoder().encode(tone);
      expect(packet.length, ImaAdpcm.headerBytes + tone.length ~/ 2);
      expect(packet.length, lessThanOrEqualTo(kMaxLiveAudioBytes));
      final decoded = ImaAdpcm.decode(packet)!;
      expect(decoded.length, tone.length);
      // Past the first few samples, where the encoder catches up.
      expect(
        _snr(tone.sublist(64), Int16List.fromList(decoded.sublist(64))),
        greaterThan(20),
      );
    });

    test('each packet stands alone: a dropped one changes nothing', () {
      final encoder = ImaAdpcmEncoder();
      final tone = _tone(kLiveAudioPacketMs * 3);
      final packets = [
        for (var i = 0; i < 3; i++)
          encoder.encode(
            Int16List.sublistView(
              tone,
              i * kLiveAudioPacketSamples,
              (i + 1) * kLiveAudioPacketSamples,
            ),
          ),
      ];
      final all = [for (final p in packets) ...ImaAdpcm.decode(p)!];
      // The third alone decodes as within the stream.
      expect(
        ImaAdpcm.decode(packets[2]),
        all.sublist(2 * kLiveAudioPacketSamples),
      );
    });

    test('extremes are clamped, silence stays silent', () {
      final loud = Int16List.fromList([
        for (var i = 0; i < 640; i++) i.isEven ? 32767 : -32768,
      ]);
      final decoded = ImaAdpcm.decode(ImaAdpcmEncoder().encode(loud))!;
      expect(decoded.every((s) => s >= -32768 && s <= 32767), isTrue);
      final quiet = ImaAdpcm.decode(ImaAdpcmEncoder().encode(Int16List(640)))!;
      expect(quiet.every((s) => s.abs() < 8), isTrue);
    });

    test('what is not a packet is refused', () {
      expect(ImaAdpcm.decode(Uint8List(4)), isNull);
      expect(ImaAdpcm.decode(Uint8List.fromList([0, 0, 89, 0, 0])), isNull);
    });
  });

  group('LiveAudioPacker', () {
    test('cuts chunks of any size, even split samples, into packets', () {
      final tone = _tone(kLiveAudioPacketMs * 5);
      final bytes = _pcm(tone);
      final packer = LiveAudioPacker();
      final random = Random(7);
      final packets = <Uint8List>[];
      var at = 0;
      while (at < bytes.length) {
        final size = min(1 + random.nextInt(901), bytes.length - at);
        packets.addAll(packer.add(Uint8List.sublistView(bytes, at, at + size)));
        at += size;
      }
      expect(packets, hasLength(5));
      // Same as encoding the packets at once.
      final encoder = ImaAdpcmEncoder();
      for (var i = 0; i < 5; i++) {
        expect(
          packets[i],
          encoder.encode(
            Int16List.sublistView(
              tone,
              i * kLiveAudioPacketSamples,
              (i + 1) * kLiveAudioPacketSamples,
            ),
          ),
        );
      }
    });

    test('reset forgets what was not sent', () {
      final packer = LiveAudioPacker();
      expect(packer.add(Uint8List(kLiveAudioPacketSamples)), isEmpty);
      packer.reset();
      expect(packer.add(Uint8List(kLiveAudioPacketSamples)), isEmpty);
      expect(packer.add(Uint8List(kLiveAudioPacketSamples)), hasLength(1));
    });
  });

  group('LiveAudioJitter', () {
    Int16List packet() => Int16List(kLiveAudioPacketSamples);
    const step = kLiveAudioPacketMs;

    test('gathers a little sound, then plays each packet as it comes', () {
      final jitter = LiveAudioJitter();
      var now = 0;
      final played = <int>[];
      for (var i = 0; i < 10; i++) {
        played.add(jitter.push(packet(), now).length);
        now += step;
      }
      final start = kLiveAudioStartMs ~/ step;
      expect(played.sublist(0, start - 1), everyElement(0));
      expect(played[start - 1], start);
      expect(played.sublist(start), everyElement(1));
      expect(jitter.dropped, 0);
    });

    test('a burst beyond the limit is dropped: the delay never grows', () {
      final jitter = LiveAudioJitter();
      var played = 0;
      // The network held back two seconds of sound, then gives it at once.
      for (var i = 0; i < 2000 ~/ step; i++) {
        played += jitter.push(packet(), 0).length;
      }
      expect(played * step, lessThanOrEqualTo(kLiveAudioMaxBufferMs));
      expect(jitter.dropped, greaterThan(0));
    });

    test('after running dry, gathers again', () {
      final jitter = LiveAudioJitter();
      var now = 0;
      for (var i = 0; i < 5; i++) {
        jitter.push(packet(), now);
        now += step;
      }
      // A second without sound: the player is dry.
      now += 1000;
      expect(jitter.push(packet(), now), isEmpty);
    });

    test('flush plays what is gathered at once', () {
      final jitter = LiveAudioJitter();
      expect(jitter.push(packet(), 0), isEmpty);
      expect(jitter.flush(10), hasLength(1));
      expect(jitter.flush(10), isEmpty);
    });
  });
}
