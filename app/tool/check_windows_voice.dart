// The real microphone through `record_windows`, as voice messages use it:
//
//   cd app && flutter run -d windows -t tool/check_windows_voice.dart
//
// Records about one second with the default microphone, then with each one
// listed in the settings; nothing is kept (the file is deleted once read).
// Prints each check and exits (code 0 when all pass).
import 'dart:io';

import 'package:dismessage/services/media_devices.dart';
import 'package:dismessage/services/voice_recorder.dart';
import 'package:flutter/widgets.dart';

var _failures = 0;

void check(bool ok, String what) {
  stdout.writeln('${ok ? 'OK   ' : 'ÉCHEC'} $what');
  if (!ok) _failures++;
}

Future<void> record(String label, String? device) async {
  final recorder = platformVoiceRecorder(microphone: () => device);
  try {
    await recorder.start();
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final voice = await recorder.stop();
    check(
      voice != null && voice.bytes.length > 100,
      '$label : ${voice?.bytes.length} octets, ${voice?.mime}, '
      '${voice?.duration.inMilliseconds} ms',
    );
  } catch (e) {
    check(false, '$label : $e');
    try {
      await recorder.cancel();
    } catch (_) {}
  } finally {
    await recorder.dispose();
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
    await record('micro par défaut', null);
    for (final microphone in microphones) {
      await record(microphone.label, microphone.id);
    }
    await record('micro débranché depuis', 'n-existe-plus');
  } catch (e) {
    check(false, 'exception : $e');
  }
  stdout.writeln(_failures == 0 ? 'TOUT EST BON' : '$_failures ÉCHEC(S)');
  exit(_failures == 0 ? 0 : 1);
}
