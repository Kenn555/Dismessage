import 'dart:async';
import 'dart:typed_data';

import 'package:dismessage/services/live_audio.dart';
import 'package:dismessage/services/recorder_pool.dart';
import 'package:dismessage/services/voice_recorder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record_platform_interface/record_platform_interface.dart';

/// The `record` plugin, by its calls.
class FakeRecord extends RecordPlatform {
  final calls = <String>[];
  final created = <String>{};
  StreamController<Uint8List>? sound;

  void _call(String method, String id) {
    if (method != 'create' && !created.contains(id)) {
      throw StateError('$method on $id, never created');
    }
    calls.add('$method $id');
  }

  @override
  Future<void> create(String recorderId) async {
    // The plugin keeps the first recorder of an ID: a second one is lost.
    if (!created.add(recorderId)) throw StateError('$recorderId created twice');
    _call('create', recorderId);
  }

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async {
    _call('hasPermission', recorderId);
    return true;
  }

  @override
  Future<Stream<Uint8List>> startStream(
    String recorderId,
    RecordConfig config,
  ) async {
    _call('startStream', recorderId);
    return (sound = StreamController<Uint8List>()).stream;
  }

  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) async => _call('start', recorderId);

  @override
  Future<bool> isEncoderSupported(
    String recorderId,
    AudioEncoder encoder,
  ) async => true;

  @override
  Future<List<InputDevice>> listInputDevices(String recorderId) async => [];

  @override
  Future<void> cancel(String recorderId) async => _call('cancel', recorderId);

  @override
  Future<void> dispose(String recorderId) async => _call('dispose', recorderId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late FakeRecord record;
  late RecordPlatform original;

  setUp(() {
    original = RecordPlatform.instance;
    RecordPlatform.instance = record = FakeRecord();
    RecorderPool.reset();
  });
  tearDown(() => RecordPlatform.instance = original);

  test('a recorder is reused, never disposed (record_windows crashes)', () async {
    final first = await RecorderPool.take();
    final second = await RecorderPool.take();
    expect(second, isNot(first));
    await RecorderPool.give(first);
    expect(await RecorderPool.take(), first);
    await RecorderPool.give(first);
    await RecorderPool.give(second);
    expect(record.calls.where((c) => c.startsWith('dispose')), isEmpty);
    expect(record.calls, contains('cancel $first'));
  });

  test('the live microphone goes off without disposing its recorder', () async {
    final received = <int>[];
    for (var i = 0; i < 3; i++) {
      final microphone = PluginLiveMicrophone(null);
      await microphone.open((pcm) => received.add(pcm.length));
      record.sound!.add(Uint8List(4));
      await Future<void>.delayed(Duration.zero);
      await microphone.close();
      // A chunk that comes late goes nowhere.
      expect(record.sound!.hasListener, isFalse);
    }
    expect(received, [4, 4, 4]);
    expect(record.calls.where((c) => c.startsWith('dispose')), isEmpty);
    // The stream stops before the recording.
    expect(record.calls.last, startsWith('cancel'));
  });

  test('a voice recorder never started touches no recorder', () async {
    final recorder = PluginVoiceRecorder();
    expect(await recorder.stop(), isNull);
    await recorder.cancel();
    await recorder.dispose();
    expect(record.calls, isEmpty);
  });
}
