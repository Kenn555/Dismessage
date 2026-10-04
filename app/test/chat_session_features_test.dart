import 'dart:convert';
import 'dart:typed_data';

import 'package:dismessage/services/chat_session.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const peer = '318343691';
const theirs = 'aaaabbbbccccdddd';

void main() {
  late ChatSession session;
  late List<Frame> sent;

  setUp(() {
    sent = [];
    session = ChatSession(sid: 's1', peer: peer, send: sent.add);
  });

  tearDown(() => session.dispose());

  ChatMessage receiveText(String text, {String mid = theirs, String? reply}) {
    session.receive(
      MessageCommitFrame(
        sid: 's1',
        seq: session.messages.length + 1,
        text: text,
        mid: mid,
        reply: reply,
      ),
    );
    return session.messages.last as ChatMessage;
  }

  ChatMessage sendText(String text, {ChatEntry? replyTo}) {
    session.updateDraft(text);
    expect(session.sendMessage(replyTo: replyTo), isTrue);
    return session.messages.last as ChatMessage;
  }

  group('ids and multi-line text', () {
    test('my messages get a valid ID shared with the peer', () {
      final mine = sendText('Bonjour\nà toi');
      final frame = sent.whereType<MessageCommitFrame>().single;
      expect(EntryId.isValid(mine.id), isTrue);
      expect(frame.mid, mine.id);
      expect(frame.text, 'Bonjour\nà toi');
      expect(mine.text, 'Bonjour\nà toi');
    });

    test('received messages keep the sender ID', () {
      expect(receiveText('Salut').id, theirs);
      expect(session.byId(theirs), isA<ChatMessage>());
    });
  });

  group('replies', () {
    test('a reply references the quoted bubble', () {
      final original = receiveText('Question ?');
      final answer = sendText('Réponse', replyTo: original);
      expect(answer.replyTo, theirs);
      expect(sent.whereType<MessageCommitFrame>().single.reply, theirs);
    });

    test('a received reply to an unknown bubble is shown without quote', () {
      final reply = receiveText('Hein ?', reply: '0000111122223333');
      expect(reply.replyTo, isNull);
    });

    test('a received reply to my message keeps the reference', () {
      final mine = sendText('Ça va ?');
      expect(receiveText('Oui', reply: mine.id).replyTo, mine.id);
    });

    test('images and voice messages can answer too', () {
      final original = receiveText('Montre');
      session.sendVoice(
        RecordedVoice(
          bytes: Uint8List.fromList([1, 2, 3]),
          mime: 'audio/mp4',
          duration: const Duration(seconds: 2),
        ),
        replyTo: original,
      );
      expect(sent.whereType<VoiceFrame>().single.reply, theirs);
    });
  });

  group('reactions', () {
    test('reacting to a peer bubble sends it, again removes it', () {
      final message = receiveText('Super');
      session.react(message, '👍');
      expect(message.reaction, '👍');
      expect(sent.whereType<ReactionFrame>().last.emoji, '👍');

      session.react(message, '❤️');
      expect(message.reaction, '❤️');

      session.react(message, '❤️');
      expect(message.reaction, isNull);
      final removal = sent.whereType<ReactionFrame>().last;
      expect((removal.ref, removal.emoji), (theirs, ''));
    });

    test('I cannot react to my own bubbles', () {
      final mine = sendText('Moi');
      session.react(mine, '👍');
      expect(mine.reaction, isNull);
      expect(sent.whereType<ReactionFrame>(), isEmpty);
    });

    test('the peer reacts to my bubbles only', () {
      final mine = sendText('Moi');
      final theirsMessage = receiveText('Eux');
      session.receive(ReactionFrame(sid: 's1', ref: mine.id, emoji: '😂'));
      session.receive(const ReactionFrame(sid: 's1', ref: theirs, emoji: '😂'));
      expect(mine.reaction, '😂');
      expect(theirsMessage.reaction, isNull);

      session.receive(ReactionFrame(sid: 's1', ref: mine.id, emoji: ''));
      expect(mine.reaction, isNull);
    });

    test('no reaction once the peer left', () {
      final message = receiveText('Bye');
      session.markPeerLeft();
      session.react(message, '👍');
      expect(sent.whereType<ReactionFrame>(), isEmpty);
    });
  });

  group('voice', () {
    test('a voice message travels whole, with its duration', () {
      final bytes = Uint8List.fromList(List.generate(100, (i) => i));
      final voice = session.sendVoice(
        RecordedVoice(
          bytes: bytes,
          mime: 'audio/mp4',
          duration: const Duration(milliseconds: 4200),
        ),
      )!;
      final frame = sent.whereType<VoiceFrame>().single;
      expect(frame.mid, voice.id);
      expect(frame.durationMs, 4200);
      expect(base64Decode(frame.data), bytes);
    });

    test('too large or empty recordings are refused', () {
      expect(
        session.sendVoice(
          RecordedVoice(
            bytes: Uint8List(kMaxVoiceBytes + 1),
            mime: 'audio/mp4',
            duration: const Duration(seconds: 10),
          ),
        ),
        isNull,
      );
      expect(
        session.sendVoice(
          RecordedVoice(
            bytes: Uint8List(0),
            mime: 'audio/mp4',
            duration: const Duration(seconds: 1),
          ),
        ),
        isNull,
      );
      expect(sent, isEmpty);
    });

    test('a received voice message is added once', () {
      final frame = VoiceFrame(
        sid: 's1',
        mid: theirs,
        durationMs: 1500,
        mime: 'audio/webm',
        data: base64Encode([9, 8, 7]),
      );
      session
        ..receive(frame)
        ..receive(frame);
      final voice = session.messages.single as ChatVoice;
      expect(voice.bytes, [9, 8, 7]);
      expect(voice.duration, const Duration(milliseconds: 1500));
      expect(voice.fromMe, isFalse);
    });
  });
}
