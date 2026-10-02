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
        sid: 'sid1', seq: 1, ops: [EditOp(pos: 0, del: 0, ins: 'Bé😀')]),
    const DraftSnapshotFrame(sid: 'sid1', seq: 2, text: 'Bonjour'),
    const DraftResyncFrame(sid: 'sid1'),
    const DraftClearFrame(sid: 'sid1', seq: 3),
    const MessageCommitFrame(sid: 'sid1', seq: 4, text: 'Salut'),
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
          '{"t":"message_commit","sid":"s","seq":1,"text":"$longText"}',
      'missing sid': '{"t":"draft_resync"}',
    };
    invalid.forEach((name, raw) {
      test(name, () {
        expect(() => Frame.decode(raw), throwsA(isA<FrameFormatException>()));
      });
    });
  });
}
