// The sound of live views on the real Windows devices:
//
//   cd app && flutter run -d windows -t tool/check_windows_audio.dart
//
// Reads two seconds of each microphone (default, each listed one, an
// unplugged one) as a live view does, and checks it comes at
// kLiveAudioSampleRate, mono; then plays a short tone, then what the
// default microphone hears, through the same chain as a live view
// (ADPCM packets, playout buffer, speaker). Nothing is kept. Prints each
// check and exits (code 0 when all pass).
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dismessage/services/live_audio.dart';
import 'package:dismessage/services/media_devices.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/widgets.dart';

var _failures = 0;

void check(bool ok, String what) {
  stdout.writeln('${ok ? 'OK   ' : 'ÉCHEC'} $what');
  if (!ok) _failures++;
}

/// Reads [ms] of [device]; the bytes, and how long they took to come.
Future<void> listen(String label, String? device, {int ms = 2000}) async {
  final microphone = platformLiveMicrophone(deviceId: device)!;
  var bytes = 0;
  var chunks = 0;
  var peak = 0;
  final clock = Stopwatch();
  try {
    await microphone.open((pcm) {
      if (!clock.isRunning) clock.start();
      bytes += pcm.length;
      chunks++;
      final data = ByteData.sublistView(pcm);
      for (var i = 0; i + 1 < pcm.length; i += 2) {
        peak = max(peak, data.getInt16(i, Endian.little).abs());
      }
    });
    await Future<void>.delayed(Duration(milliseconds: ms));
    final elapsed = clock.elapsedMilliseconds;
    await microphone.close();
    // 16-bit mono: two bytes per sample.
    final rate = elapsed == 0 ? 0 : bytes / 2 * 1000 / elapsed;
    check(
      (rate - kLiveAudioSampleRate).abs() < kLiveAudioSampleRate * 0.15,
      '$label : ${rate.round()} échantillons/s (attendu '
      '$kLiveAudioSampleRate), $chunks morceaux, crête $peak',
    );
  } catch (e) {
    check(false, '$label : $e');
    await microphone.close();
  }
}

Future<void> playTone() async {
  final speaker = platformLiveSpeaker()!;
  try {
    await speaker.open();
    const ms = 600;
    final tone = Int16List(kLiveAudioSampleRate * ms ~/ 1000);
    for (var i = 0; i < tone.length; i++) {
      tone[i] = (6000 * sin(2 * pi * 440 * i / kLiveAudioSampleRate)).round();
    }
    for (var at = 0; at < tone.length; at += kLiveAudioPacketSamples) {
      speaker.play(Int16List.sublistView(tone, at, at + kLiveAudioPacketSamples));
    }
    await Future<void>.delayed(const Duration(milliseconds: ms + 200));
    check(true, 'haut-parleur : la1 de 0,6 s joué');
  } catch (e) {
    check(false, 'haut-parleur : $e');
  } finally {
    await speaker.close();
  }
}

/// The default microphone heard through the whole chain.
Future<void> loopback() async {
  final microphone = platformLiveMicrophone()!;
  final speaker = platformLiveSpeaker()!;
  final packer = LiveAudioPacker();
  final jitter = LiveAudioJitter();
  final clock = Stopwatch()..start();
  var packets = 0;
  try {
    await speaker.open();
    await microphone.open((pcm) {
      for (final packet in packer.add(pcm)) {
        packets++;
        final samples = ImaAdpcm.decode(packet)!;
        jitter
            .push(samples, clock.elapsedMilliseconds)
            .forEach(speaker.play);
      }
    });
    await Future<void>.delayed(const Duration(seconds: 3));
    check(
      packets >= 3000 ~/ kLiveAudioPacketMs * 0.8,
      'micro → ADPCM → haut-parleur : $packets paquets en 3 s, '
      '${jitter.dropped} écartés',
    );
  } catch (e) {
    check(false, 'micro → haut-parleur : $e');
  } finally {
    await microphone.close();
    await speaker.close();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox());
  try {
    final microphones = await platformMediaDevices().microphones();
    stdout.writeln(
      'Micros : ${microphones.map((m) => '${m.label} [${m.id}]').join(', ')}',
    );
    await listen('micro par défaut', null);
    for (final microphone in microphones) {
      await listen(microphone.label, microphone.id);
    }
    await listen('micro débranché depuis', 'n-existe-plus');
    await playTone();
    await loopback();
  } catch (e) {
    check(false, 'exception : $e');
  }
  stdout.writeln(_failures == 0 ? 'TOUT EST BON' : '$_failures ÉCHEC(S)');
  exit(_failures == 0 ? 0 : 1);
}
