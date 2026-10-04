import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:test/test.dart';

/// Feeds a sender frame into a receiver, like the relay would.
DraftUpdate deliver(DraftState state, RelayedFrame frame) => switch (frame) {
  DraftOpsFrame f => state.applyOps(f.seq, f.ops),
  DraftSnapshotFrame f => state.applySnapshot(f.seq, f.text),
  DraftClearFrame f => state.clear(f.seq),
  MessageCommitFrame f =>
    state.commit(f.seq, f.text) != null
        ? DraftUpdate.applied
        : DraftUpdate.ignored,
  DraftResyncFrame() ||
  ImageOfferFrame() ||
  ImageRequestFrame() ||
  ImageDataFrame() ||
  VoiceFrame() ||
  ReactionFrame() => DraftUpdate.ignored,
};

void main() {
  group('DraftState', () {
    test('applies ops in order', () {
      final s = DraftState();
      expect(
        s.applyOps(1, [const EditOp(pos: 0, del: 0, ins: 'Bon')]),
        DraftUpdate.applied,
      );
      expect(
        s.applyOps(2, [const EditOp(pos: 3, del: 0, ins: 'jour')]),
        DraftUpdate.applied,
      );
      expect(s.text, 'Bonjour');
      expect(s.lastSeq, 2);
    });

    test('ignores duplicates', () {
      final s = DraftState();
      s.applyOps(1, [const EditOp(pos: 0, del: 0, ins: 'a')]);
      expect(
        s.applyOps(1, [const EditOp(pos: 0, del: 0, ins: 'a')]),
        DraftUpdate.ignored,
      );
      expect(s.text, 'a');
    });

    test('gap triggers resync and blocks ops until snapshot', () {
      final s = DraftState();
      s.applyOps(1, [const EditOp(pos: 0, del: 0, ins: 'a')]);
      expect(
        s.applyOps(3, [const EditOp(pos: 1, del: 0, ins: 'c')]),
        DraftUpdate.needsResync,
      );
      expect(s.awaitingResync, isTrue);
      expect(
        s.applyOps(4, [const EditOp(pos: 0, del: 0, ins: 'x')]),
        DraftUpdate.ignored,
      );
      expect(s.applySnapshot(5, 'abcd'), DraftUpdate.applied);
      expect(s.awaitingResync, isFalse);
      expect(s.text, 'abcd');
      expect(
        s.applyOps(6, [const EditOp(pos: 4, del: 0, ins: 'e')]),
        DraftUpdate.applied,
      );
      expect(s.text, 'abcde');
    });

    test('op that does not fit triggers resync', () {
      final s = DraftState();
      expect(
        s.applyOps(1, [const EditOp(pos: 5, del: 0, ins: 'x')]),
        DraftUpdate.needsResync,
      );
      expect(s.text, '');
    });

    test('stale snapshot is ignored', () {
      final s = DraftState();
      s.applySnapshot(3, 'abc');
      expect(s.applySnapshot(2, 'old'), DraftUpdate.ignored);
      expect(s.text, 'abc');
    });

    test('clear and commit reset the draft', () {
      final s = DraftState();
      s.applyOps(1, [const EditOp(pos: 0, del: 0, ins: 'abc')]);
      expect(s.clear(2), DraftUpdate.applied);
      expect(s.text, '');
      s.applyOps(3, [const EditOp(pos: 0, del: 0, ins: 'Salut')]);
      expect(s.commit(4, 'Salut'), 'Salut');
      expect(s.text, '');
      expect(s.commit(4, 'Salut'), isNull, reason: 'duplicate commit');
    });
  });

  group('DraftSender', () {
    test('nothing to flush initially', () {
      final sender = DraftSender('s1');
      expect(sender.hasPending, isFalse);
      expect(sender.flush(), isNull);
    });

    test('coalesces consecutive appends into one op', () {
      final sender = DraftSender('s1');
      for (final t in ['B', 'Bo', 'Bon', 'Bonj']) {
        sender.update(t);
      }
      final frame = sender.flush() as DraftOpsFrame;
      expect(frame.seq, 1);
      expect(frame.ops, [const EditOp(pos: 0, del: 0, ins: 'Bonj')]);
      expect(sender.flush(), isNull);
    });

    test('sends clear when the field is emptied', () {
      final sender = DraftSender('s1')..update('abc');
      sender.flush();
      sender.update('');
      expect(sender.flush(), isA<DraftClearFrame>());
    });

    test('sends a snapshot every kSnapshotEvery ops', () {
      final sender = DraftSender('s1');
      final frames = <RelayedFrame>[];
      var text = '';
      for (var i = 0; i < kSnapshotEvery; i++) {
        // Alternate insert/delete so ops never coalesce.
        text = i.isEven ? '${text}ab' : text.substring(0, text.length - 1);
        sender.update(text);
        frames.add(sender.flush()!);
      }
      expect(frames.whereType<DraftSnapshotFrame>(), hasLength(1));
      expect(frames.last, isA<DraftSnapshotFrame>());
    });

    test('requestSnapshot forces a snapshot', () {
      final sender = DraftSender('s1')..update('abc');
      sender.flush();
      sender.requestSnapshot();
      final frame = sender.flush() as DraftSnapshotFrame;
      expect(frame.text, 'abc');
    });

    test('commit ignores blank text and resets the draft', () {
      final sender = DraftSender('s1')..update('   ');
      expect(sender.commit(), isNull);
      sender.update('Salut');
      final frame = sender.commit(reply: '0123456789abcdef')!;
      expect(frame.text, 'Salut');
      expect(EntryId.isValid(frame.mid), isTrue);
      expect(frame.reply, '0123456789abcdef');
      expect(sender.text, '');
      expect(sender.hasPending, isFalse);
    });
  });

  test('sender and receiver stay in sync over a typing session', () {
    final sender = DraftSender('s1');
    final receiver = DraftState();
    const typed = [
      'S', 'Sa', 'Sal', 'Salu', 'Salut', 'Salut ', 'Salut c', 'Salut ç', //
      'Salut ça', 'Salut ça v', 'Salut ça va', 'Salut, ça va',
      'Salut, ça va ?', 'Salut, ça va ? 😀',
    ];
    for (var i = 0; i < typed.length; i++) {
      sender.update(typed[i]);
      if (i.isOdd) deliver(receiver, sender.flush()!);
    }
    final last = sender.flush();
    if (last != null) deliver(receiver, last);
    expect(receiver.text, typed.last);

    final commit = sender.commit()!;
    expect(receiver.commit(commit.seq, commit.text), typed.last);
    expect(receiver.text, '');
  });

  test('receiver recovers from a lost frame via resync', () {
    final sender = DraftSender('s1');
    final receiver = DraftState();
    sender.update('Bon');
    deliver(receiver, sender.flush()!);
    sender.update('Bonjour');
    sender.flush(); // lost
    sender.update('Bonjour !');
    expect(deliver(receiver, sender.flush()!), DraftUpdate.needsResync);
    sender.requestSnapshot();
    deliver(receiver, sender.flush()!);
    expect(receiver.text, 'Bonjour !');
  });
}
