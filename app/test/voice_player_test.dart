import 'dart:typed_data';

import 'package:dismessage/services/chat_session.dart';
import 'package:dismessage/services/voice_player.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

class FailingBackend extends FakeAudioBackend {
  @override
  Future<void> play(Uint8List bytes, String mime) async =>
      throw StateError('format refusé');
}

ChatVoice voice(String id) => ChatVoice(
  id: id,
  bytes: Uint8List.fromList([1, 2, 3]),
  mime: 'audio/webm;codecs=opus',
  duration: const Duration(seconds: 2),
  fromMe: false,
);

void main() {
  test('codec parameters are dropped for the player', () {
    // Kept, they end up escaped in a data: URI the browser cannot play.
    expect(baseMime('audio/webm;codecs=opus'), 'audio/webm');
    expect(baseMime('audio/webm; codecs=opus'), 'audio/webm');
    expect(baseMime('audio/mp4'), 'audio/mp4');
  });

  test('a playback failure keeps its cause', () async {
    final player = VoicePlayer(FailingBackend.new);
    addTearDown(player.dispose);
    await player.toggle(voice('aaaabbbbccccdddd'));
    expect(player.error, contains('format refusé'));
    expect(player.currentId, isNull);
  });

  test('play, pause, resume, then the end resets', () async {
    late FakeAudioBackend backend;
    final player = VoicePlayer(() => backend = FakeAudioBackend());
    addTearDown(player.dispose);
    final v = voice('aaaabbbbccccdddd');

    await player.toggle(v);
    expect(player.isPlaying(v), isTrue);
    await player.toggle(v);
    expect((player.isPlaying(v), backend.paused), (false, true));
    await player.toggle(v);
    expect(player.isPlaying(v), isTrue);

    backend.complete();
    await Future<void>.delayed(Duration.zero);
    expect(player.isPlaying(v), isFalse);
    expect(player.currentId, isNull);
  });
}
