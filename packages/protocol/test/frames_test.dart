import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:test/test.dart';

const a = '482913075';
const b = '123456789';

void main() {
  final samples = <Frame>[
    const RegisterFrame(id: a, secret: 's3cr3t'),
    const RegisteredFrame(id: a),
    const IdTakenFrame(id: a),
    const ReleaseFrame(id: a, secret: 's3cr3t'),
    const ConnectRequestFrame(to: b),
    const IncomingRequestFrame(from: a),
    const ConnectAcceptFrame(from: a),
    const ConnectRejectFrame(peer: b),
    const ConnectCancelFrame(peer: b),
    const SessionStartedFrame(sid: 'sid1', peer: b),
    const PeerOfflineFrame(peer: b),
    const PeerLeftFrame(sid: 'sid1'),
    const SessionLeaveFrame(sid: 'sid1'),
    const DraftOpsFrame(
      sid: 'sid1',
      seq: 1,
      ops: [EditOp(pos: 0, del: 0, ins: 'Bé😀')],
    ),
    const DraftSnapshotFrame(sid: 'sid1', seq: 2, text: 'Bonjour'),
    const DraftResyncFrame(sid: 'sid1'),
    const DraftClearFrame(sid: 'sid1', seq: 3),
    const MessageCommitFrame(
      sid: 'sid1',
      seq: 4,
      text: 'Salut\nÇa va ?',
      mid: 'aaaabbbbccccdddd',
      reply: '0123456789abcdef',
    ),
    const ImageOfferFrame(
      sid: 'sid1',
      img: '0123456789abcdef',
      width: 1280,
      height: 960,
      preview: '/9j/4AAQSkZJRg==',
      reply: 'aaaabbbbccccdddd',
    ),
    const ImageRequestFrame(sid: 'sid1', img: '0123456789abcdef'),
    const ImageDataFrame(
      sid: 'sid1',
      img: '0123456789abcdef',
      data: '/9j/4AAQSkZJRgABAQ==',
    ),
    const VoiceFrame(
      sid: 'sid1',
      mid: 'ffffeeeeddddcccc',
      durationMs: 4200,
      mime: 'audio/webm;codecs=opus',
      data: 'GkXfo59ChoEBQveBAULygQ==',
      reply: 'aaaabbbbccccdddd',
    ),
    const ReactionFrame(sid: 'sid1', ref: 'aaaabbbbccccdddd', emoji: '❤️'),
    const PresenceWatchFrame(ids: [a, b]),
    const PresenceFrame(id: b, online: true),
    const ErrorFrame(code: 'bad_frame', message: 'oops'),
    const PingFrame(),
    const PongFrame(),
  ];

  test('every frame type has a sample', () {
    expect(samples.map((f) => f.type).toSet(), hasLength(samples.length));
  });

  for (final frame in samples) {
    test('round trip ${frame.type}', () {
      final decoded = Frame.decode(frame.encode());
      expect(decoded.runtimeType, frame.runtimeType);
      expect(decoded.toJson(), frame.toJson());
    });
  }

  group('optional fields', () {
    test('a message without reply omits the field', () {
      const frame = MessageCommitFrame(
        sid: 's',
        seq: 1,
        text: 'x',
        mid: 'aaaabbbbccccdddd',
      );
      expect(frame.toJson().containsKey('reply'), isFalse);
      final decoded = Frame.decode(frame.encode()) as MessageCommitFrame;
      expect(decoded.reply, isNull);
    });

    test('an empty emoji removes a reaction', () {
      final decoded = Frame.decode(
        '{"t":"reaction","sid":"s","ref":"aaaabbbbccccdddd","emoji":""}',
      );
      expect((decoded as ReactionFrame).emoji, isEmpty);
    });

    test('an empty presence list is allowed', () {
      final decoded = Frame.decode('{"t":"presence_watch","ids":[]}');
      expect((decoded as PresenceWatchFrame).ids, isEmpty);
    });
  });

  group('rejects invalid frames', () {
    final longSecret = 'x' * (kMaxSecretLength + 1);
    final longText = 'x' * (kMaxTextLength + 1);
    final invalid = <String, Object?>{
      'not a string': 42,
      'invalid JSON': '{nope',
      'not an object': '[1,2]',
      'missing type': '{"id":"$a"}',
      'unknown type': '{"t":"hack"}',
      'bad id': '{"t":"register","id":"012345678","secret":"x"}',
      'empty secret': '{"t":"register","id":"$a","secret":""}',
      'secret too long': '{"t":"register","id":"$a","secret":"$longSecret"}',
      'seq zero': '{"t":"draft_clear","sid":"s","seq":0}',
      'seq string': '{"t":"draft_clear","sid":"s","seq":"1"}',
      'empty ops': '{"t":"draft_ops","sid":"s","seq":1,"ops":[]}',
      'bad op':
          '{"t":"draft_ops","sid":"s","seq":1,"ops":[{"pos":-1,"del":0,"ins":""}]}',
      'text too long':
          '{"t":"message_commit","sid":"s","seq":1,"text":"$longText","mid":"aaaabbbbccccdddd"}',
      'message without mid':
          '{"t":"message_commit","sid":"s","seq":1,"text":"x"}',
      'bad reply id':
          '{"t":"message_commit","sid":"s","seq":1,"text":"x","mid":"aaaabbbbccccdddd","reply":"../x"}',
      'reaction too long':
          '{"t":"reaction","sid":"s","ref":"aaaabbbbccccdddd","emoji":"${'x' * (kMaxReactionLength + 1)}"}',
      'reaction not a string':
          '{"t":"reaction","sid":"s","ref":"aaaabbbbccccdddd","emoji":1}',
      'reaction bad ref': '{"t":"reaction","sid":"s","ref":"NOPE","emoji":"x"}',
      'presence list too long':
          '{"t":"presence_watch","ids":[${List.filled(kMaxPresenceWatch + 1, '"$a"').join(',')}]}',
      'presence bad id': '{"t":"presence_watch","ids":["12"]}',
      'presence not a list': '{"t":"presence_watch","ids":"$a"}',
      'presence online not bool': '{"t":"presence","id":"$a","online":1}',
      'voice not audio':
          '{"t":"voice","sid":"s","mid":"aaaabbbbccccdddd","ms":1000,"mime":"text/html","data":"AA=="}',
      'voice too long':
          '{"t":"voice","sid":"s","mid":"aaaabbbbccccdddd","ms":${(kMaxVoiceSeconds + 6) * 1000},"mime":"audio/mp4","data":"AA=="}',
      'voice too large':
          '{"t":"voice","sid":"s","mid":"aaaabbbbccccdddd","ms":1000,"mime":"audio/mp4","data":"${'A' * (kMaxVoiceDataLength + 1)}"}',
      'missing sid': '{"t":"draft_resync"}',
      'bad image id': '{"t":"image_request","sid":"s","img":"../etc"}',
      'image dimension zero':
          '{"t":"image_offer","sid":"s","img":"0123456789abcdef","w":0,"h":10,"preview":"AA=="}',
      'preview not base64':
          '{"t":"image_offer","sid":"s","img":"0123456789abcdef","w":10,"h":10,"preview":"<script>"}',
      'preview too large':
          '{"t":"image_offer","sid":"s","img":"0123456789abcdef","w":10,"h":10,"preview":"${'A' * (kMaxImagePreviewLength + 1)}"}',
      'image too large':
          '{"t":"image_data","sid":"s","img":"0123456789abcdef","data":"${'A' * (kMaxImageDataLength + 1)}"}',
    };
    invalid.forEach((name, raw) {
      test(name, () {
        expect(() => Frame.decode(raw), throwsA(isA<FrameFormatException>()));
      });
    });
  });
}
