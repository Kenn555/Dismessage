import 'dart:async';
import 'dart:typed_data';

import 'package:dismessage/services/chat_session.dart';
import 'package:dismessage/services/voice_player.dart';
import 'package:dismessage/services/voice_recorder.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Records what the app sends.
class RecordingSink implements WebSocketSink {
  final sent = <Frame>[];

  @override
  void add(Object? data) => sent.add(Frame.decode(data));

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A connected channel whose server side is driven by the test.
class ScriptedChannel implements WebSocketChannel {
  final server = StreamController<Object?>();
  @override
  final RecordingSink sink = RecordingSink();

  void receive(Frame frame) => server.add(frame.encode());

  @override
  Future<void> get ready async {}

  @override
  Stream<Object?> get stream => server.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A handshake that never completes (blocked by a proxy, firewall…).
class HangingChannel implements WebSocketChannel {
  @override
  Future<void> get ready => Completer<void>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Microphone driven by the test.
class FakeVoiceRecorder implements VoiceRecorder {
  FakeVoiceRecorder({this.result, this.failure});

  /// What [stop] returns.
  RecordedVoice? result;

  /// Thrown by [start] (e.g. permission denied).
  VoiceRecorderException? failure;
  bool recording = false;
  int cancelled = 0;

  @override
  Duration maxDuration = const Duration(seconds: kMaxVoiceSeconds);

  @override
  Future<void> start() async {
    final failure = this.failure;
    if (failure != null) throw failure;
    recording = true;
  }

  @override
  Future<RecordedVoice?> stop() async {
    recording = false;
    return result;
  }

  @override
  Future<void> cancel() async {
    recording = false;
    cancelled++;
  }

  @override
  Future<void> dispose() async {}
}

/// Audio output that only records what it was asked to play.
class FakeAudioBackend implements AudioBackend {
  final played = <Uint8List>[];
  final _positions = StreamController<Duration>.broadcast();
  final _completions = StreamController<void>.broadcast();
  bool paused = false;

  void complete() => _completions.add(null);

  @override
  Future<void> play(Uint8List bytes, String mime) async => played.add(bytes);

  @override
  Future<void> pause() async => paused = true;

  @override
  Future<void> resume() async => paused = false;

  @override
  Future<void> stop() async {}

  @override
  Stream<Duration> get positions => _positions.stream;

  @override
  Stream<void> get completions => _completions.stream;

  @override
  Future<void> dispose() async {
    await _positions.close();
    await _completions.close();
  }
}
