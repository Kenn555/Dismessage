import 'dart:typed_data';

import 'constants.dart';

/// IMA ADPCM, 4 bits per sample, packets that stand alone: each one starts
/// with the encoder's state (predicted sample, then step index), so that a
/// dropped packet never garbles the next ones.
///
/// Packet: predicted sample (int16, little endian), step index (0 to 88), a
/// zero byte, then two samples per byte, the first in the low nibble.
abstract final class ImaAdpcm {
  static const headerBytes = 4;

  static const _steps = <int>[
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, //
    41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173,
    190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658,
    724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
    2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484,
    7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500,
    20350, 22385, 24623, 27086, 29794, 32767,
  ];
  static const _indexMoves = <int>[-1, -1, -1, -1, 2, 4, 6, 8];

  /// Samples in a packet of [bytes] bytes; 0 if it cannot be one.
  static int samplesIn(int bytes) =>
      bytes <= headerBytes ? 0 : (bytes - headerBytes) * 2;

  /// Decodes a packet; null if it is not one.
  static Int16List? decode(Uint8List packet) {
    final count = samplesIn(packet.length);
    if (count == 0 || packet[2] > 88) return null;
    var predicted = (packet[0] | packet[1] << 8).toSigned(16);
    var index = packet[2];
    final out = Int16List(count);
    for (var i = 0; i < count; i++) {
      final byte = packet[headerBytes + (i >> 1)];
      final nibble = i.isEven ? byte & 0x0f : byte >> 4;
      (predicted, index) = _step(predicted, index, nibble);
      out[i] = predicted;
    }
    return out;
  }

  static (int, int) _step(int predicted, int index, int nibble) {
    final step = _steps[index];
    var delta = step >> 3;
    if (nibble & 4 != 0) delta += step;
    if (nibble & 2 != 0) delta += step >> 1;
    if (nibble & 1 != 0) delta += step >> 2;
    predicted += nibble & 8 != 0 ? -delta : delta;
    if (predicted > 32767) predicted = 32767;
    if (predicted < -32768) predicted = -32768;
    index += _indexMoves[nibble & 7];
    if (index < 0) index = 0;
    if (index > 88) index = 88;
    return (predicted, index);
  }
}

/// Encodes sound into ADPCM packets, keeping its state from one to the next.
class ImaAdpcmEncoder {
  int _predicted = 0;
  int _index = 0;

  /// Encodes an even number of [samples] into a packet.
  Uint8List encode(Int16List samples) {
    assert(samples.length.isEven && samples.isNotEmpty);
    final out = Uint8List(ImaAdpcm.headerBytes + samples.length ~/ 2)
      ..[0] = _predicted & 0xff
      ..[1] = (_predicted >> 8) & 0xff
      ..[2] = _index;
    for (var i = 0; i < samples.length; i++) {
      final nibble = _nibbleFor(samples[i]);
      final (predicted, index) = ImaAdpcm._step(_predicted, _index, nibble);
      _predicted = predicted;
      _index = index;
      out[ImaAdpcm.headerBytes + (i >> 1)] |= i.isEven ? nibble : nibble << 4;
    }
    return out;
  }

  int _nibbleFor(int sample) {
    var step = ImaAdpcm._steps[_index];
    var difference = sample - _predicted;
    var nibble = 0;
    if (difference < 0) {
      nibble = 8;
      difference = -difference;
    }
    if (difference >= step) {
      nibble |= 4;
      difference -= step;
    }
    step >>= 1;
    if (difference >= step) {
      nibble |= 2;
      difference -= step;
    }
    step >>= 1;
    if (difference >= step) nibble |= 1;
    return nibble;
  }

  void reset() {
    _predicted = 0;
    _index = 0;
  }
}

/// Cuts the microphone's sound (16-bit little-endian PCM, at
/// [kLiveAudioSampleRate], in chunks of any size) into packets of
/// [kLiveAudioPacketSamples], encoded.
class LiveAudioPacker {
  final _encoder = ImaAdpcmEncoder();
  final _samples = Int16List(kLiveAudioPacketSamples);
  int _count = 0;

  /// A lone byte of a sample split between two chunks.
  int? _carry;

  /// The packets completed by [pcm].
  List<Uint8List> add(Uint8List pcm) {
    final packets = <Uint8List>[];
    var i = 0;
    void push(int sample) {
      _samples[_count++] = sample.toSigned(16);
      if (_count < kLiveAudioPacketSamples) return;
      packets.add(_encoder.encode(_samples));
      _count = 0;
    }

    final carry = _carry;
    if (carry != null && pcm.isNotEmpty) {
      push(carry | pcm[0] << 8);
      _carry = null;
      i = 1;
    }
    for (; i + 1 < pcm.length; i += 2) {
      push(pcm[i] | pcm[i + 1] << 8);
    }
    if (i < pcm.length) _carry = pcm[i];
    return packets;
  }

  /// Forgets what was not sent (the microphone was muted).
  void reset() {
    _count = 0;
    _carry = null;
    _encoder.reset();
  }
}

/// The playout buffer of the sound: gathers [startMs] before playing, then
/// hands over each packet as it comes, unless more than [maxMs] would wait:
/// the packet is dropped, so the delay never grows. The player plays what it
/// is given, one after the other; when it has run dry (by this clock), the
/// buffer fills up again first.
class LiveAudioJitter {
  LiveAudioJitter({
    this.startMs = kLiveAudioStartMs,
    this.maxMs = kLiveAudioMaxBufferMs,
  });

  final int startMs;
  final int maxMs;

  /// When what the player was given ends; null while filling up.
  int? _playEnd;
  final List<Int16List> _held = [];
  int _heldMs = 0;

  /// Packets dropped so far, for the tests.
  int dropped = 0;

  static int _ms(Int16List samples) =>
      samples.length * 1000 ~/ kLiveAudioSampleRate;

  /// What to play now, received at [now] (milliseconds).
  List<Int16List> push(Int16List samples, int now) {
    final ms = _ms(samples);
    final end = _playEnd;
    if (end == null || end <= now) {
      _playEnd = null;
      _held.add(samples);
      _heldMs += ms;
      if (_heldMs < startMs) return const [];
      return flush(now);
    }
    if (end - now + ms > maxMs) {
      dropped++;
      return const [];
    }
    _playEnd = end + ms;
    return [samples];
  }

  /// Plays what is gathered at once (the sound stops for a while).
  List<Int16List> flush(int now) {
    if (_held.isEmpty) return const [];
    final out = List.of(_held);
    _playEnd = now + _heldMs;
    _held.clear();
    _heldMs = 0;
    return out;
  }

  void reset() {
    _playEnd = null;
    _held.clear();
    _heldMs = 0;
  }
}
