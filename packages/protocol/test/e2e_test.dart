import 'dart:convert';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:test/test.dart';

const sid = 'abcdef0123456789';

/// Two sides of one conversation, keys exchanged.
Future<(E2eSession, E2eSession)> pair() async {
  final a = E2eSession(sid);
  final b = E2eSession(sid);
  final offerA = await a.offer();
  final offerB = await b.offer();
  await a.accept(offerB);
  await b.accept(offerA);
  return (a, b);
}

/// What the relay passes on: the frame as text, decoded again.
SealedFrame wire(SealedFrame frame) =>
    Frame.decode(frame.encode()) as SealedFrame;

void main() {
  test('a frame sealed by one side opens on the other', () async {
    final (a, b) = await pair();
    const frame = DraftOpsFrame(
      sid: sid,
      seq: 1,
      ops: [EditOp(pos: 0, del: 0, ins: 'Bonjour 😀')],
    );
    final sealed = await a.seal(frame);
    expect(sealed.encode(), isNot(contains('Bonjour')));
    final opened = await b.open(wire(sealed));
    expect(opened.toJson(), frame.toJson());
  });

  test('both directions, many frames, in order', () async {
    final (a, b) = await pair();
    for (var i = 1; i <= 50; i++) {
      final fromA = DraftSnapshotFrame(sid: sid, seq: i, text: 'a$i');
      final fromB = DraftSnapshotFrame(sid: sid, seq: i, text: 'b$i');
      expect(
        (await b.open(wire(await a.seal(fromA)))).toJson(),
        fromA.toJson(),
      );
      expect(
        (await a.open(wire(await b.seal(fromB)))).toJson(),
        fromB.toJson(),
      );
    }
  });

  test('the largest frame (a full image) fits once sealed', () async {
    final (a, b) = await pair();
    final frame = ImageDataFrame(
      sid: sid,
      img: EntryId.generate(),
      data: 'A' * kMaxImageDataLength,
    );
    final sealed = await a.seal(frame);
    expect(sealed.data.length, lessThanOrEqualTo(kMaxSealedDataLength));
    expect(sealed.encode().length, lessThanOrEqualTo(kMaxFrameLength));
    final opened = await b.open(wire(sealed)) as ImageDataFrame;
    expect(opened.data, frame.data);
  });

  test('frames sealed before the key exchange wait for it', () async {
    final a = E2eSession(sid);
    final b = E2eSession(sid);
    const frame = DraftSnapshotFrame(sid: sid, seq: 1, text: 'tôt');
    final pending = a.seal(frame);
    expect(a.isReady, isFalse);
    await a.accept(await b.offer());
    await b.accept(await a.offer());
    expect((await b.open(await pending)).toJson(), frame.toJson());
  });

  group('refused', () {
    test('an altered frame', () async {
      final (a, b) = await pair();
      final sealed = await a.seal(
        const DraftSnapshotFrame(sid: sid, seq: 1, text: 'secret'),
      );
      final bytes = base64.decode(sealed.data);
      bytes[0] ^= 1;
      final altered = SealedFrame(
        sid: sid,
        n: sealed.n,
        data: base64.encode(bytes),
      );
      expect(() => b.open(altered), throwsA(isA<E2eException>()));
    });

    test('a replayed or reordered frame', () async {
      final (a, b) = await pair();
      final first = await a.seal(
        const DraftSnapshotFrame(sid: sid, seq: 1, text: 'un'),
      );
      final second = await a.seal(
        const DraftSnapshotFrame(sid: sid, seq: 2, text: 'deux'),
      );
      await b.open(second);
      expect(() => b.open(first), throwsA(isA<E2eException>()));
      expect(() => b.open(second), throwsA(isA<E2eException>()));
    });

    test('a frame given another counter (the nonce)', () async {
      final (a, b) = await pair();
      final sealed = await a.seal(
        const DraftSnapshotFrame(sid: sid, seq: 1, text: 'x'),
      );
      final moved = SealedFrame(sid: sid, n: 5, data: sealed.data);
      expect(() => b.open(moved), throwsA(isA<E2eException>()));
    });

    test('our own frame sent back to us (one key per direction)', () async {
      final (a, _) = await pair();
      final sealed = await a.seal(
        const DraftSnapshotFrame(sid: sid, seq: 1, text: 'x'),
      );
      expect(() => a.open(sealed), throwsA(isA<E2eException>()));
    });

    test('a frame from another conversation', () async {
      final (a, _) = await pair();
      final other = E2eSession('ffffffffffffffff');
      await other.accept(await E2eSession('ffffffffffffffff').offer());
      final sealed = await a.seal(
        const DraftSnapshotFrame(sid: sid, seq: 1, text: 'x'),
      );
      expect(() => other.open(sealed), throwsA(isA<E2eException>()));
    });

    test('a second key in the same conversation', () async {
      final (a, _) = await pair();
      final intruder = await E2eSession(sid).offer();
      expect(() => a.accept(intruder), throwsA(isA<E2eException>()));
    });

    test('a key of the wrong size, or a weak one', () async {
      expect(
        () => E2eSession(
          sid,
        ).accept(KeyOfferFrame(sid: sid, key: base64Url.encode([1, 2, 3]))),
        throwsA(isA<E2eException>()),
      );
      expect(
        () => E2eSession(sid).accept(
          KeyOfferFrame(sid: sid, key: base64Url.encode(List.filled(32, 0))),
        ),
        throwsA(isA<E2eException>()),
      );
    });

    test('opening before the key exchange', () async {
      final (a, _) = await pair();
      final sealed = await a.seal(
        const DraftSnapshotFrame(sid: sid, seq: 1, text: 'x'),
      );
      expect(() => E2eSession(sid).open(sealed), throwsA(isA<E2eException>()));
    });

    test('sealing a frame of another conversation, or a key offer', () async {
      final (a, _) = await pair();
      expect(
        () => a.seal(const DraftClearFrame(sid: 'other', seq: 1)),
        throwsArgumentError,
      );
      expect(
        () => a.seal(KeyOfferFrame(sid: sid, key: 'k')),
        throwsArgumentError,
      );
    });
  });

  group('safety code', () {
    test('the same on both sides: 4 groups of 5 digits', () async {
      final (a, b) = await pair();
      final code = await a.safetyCode();
      expect(code, matches(RegExp(r'^\d{5} \d{5} \d{5} \d{5}$')));
      expect(await b.safetyCode(), code);
    });

    test('different when the relay sits in the middle', () async {
      // A believes it talks to B, B to A; both talk to the relay M.
      final a = E2eSession(sid);
      final b = E2eSession(sid);
      final mToA = E2eSession(sid);
      final mToB = E2eSession(sid);
      await a.accept(await mToA.offer());
      await mToA.accept(await a.offer());
      await b.accept(await mToB.offer());
      await mToB.accept(await b.offer());
      // M can read everything...
      final sealed = await a.seal(
        const DraftSnapshotFrame(sid: sid, seq: 1, text: 'lu par M'),
      );
      expect(await mToA.open(sealed), isA<DraftSnapshotFrame>());
      // ...but A and B see different codes.
      expect(await a.safetyCode(), isNot(await b.safetyCode()));
    });

    test('none before the key exchange', () async {
      expect(await E2eSession(sid).safetyCode(), isNull);
    });
  });
}
