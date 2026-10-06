import 'dart:typed_data';

import 'package:dismessage/services/chat_session.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Uint8List content(int size) =>
    Uint8List.fromList(List.generate(size, (i) => (i * 7 + i ~/ 300) % 256));

void main() {
  late ChatSession alice;
  late ChatSession bob;
  late List<Frame> wire;
  late MemoryFileStorage disk;

  /// Frames from alice to bob are held while true (a slow receiver).
  var holdToBob = false;
  final heldToBob = <RelayedFrame>[];

  setUp(() {
    wire = [];
    disk = MemoryFileStorage();
    holdToBob = false;
    heldToBob.clear();
    // Two sessions connected by a fake relay that records every frame.
    alice = ChatSession(
      sid: 's',
      peer: '222222222',
      send: (f) {
        wire.add(f);
        if (holdToBob) {
          heldToBob.add(f as RelayedFrame);
        } else {
          bob.receive(f as RelayedFrame);
        }
      },
      files: MemoryFileStorage(),
    );
    bob = ChatSession(
      sid: 's',
      peer: '111111111',
      send: (f) {
        wire.add(f);
        alice.receive(f as RelayedFrame);
      },
      files: disk,
    );
  });

  tearDown(() {
    alice.dispose();
    bob.dispose();
  });

  Future<void> settle() => pumpEventQueue(times: 500);

  test('only the offer travels until the receiver accepts', () async {
    final source = FakeChosenFile('rapport.pdf', content(1000));
    final sent = alice.sendFile(source)!;
    await settle();

    expect(sent.status, FileStatus.awaiting);
    expect(wire.single, isA<FileOfferFrame>());
    expect(source.reads, isEmpty);
    final received = bob.messages.single as ChatFile;
    expect((received.name, received.size), ('rapport.pdf', 1000));
    expect(received.status, FileStatus.awaiting);
    expect(received.id, sent.id);
    expect(disk.sinks, isEmpty, reason: 'nothing written before accepting');
  });

  test('accepting writes the whole file to disk, chunk by chunk', () async {
    final bytes = content(kFileChunkBytes * 9 + 123);
    final source = FakeChosenFile('vidéo.mp4', bytes);
    final sent = alice.sendFile(source)!;
    final received = bob.messages.single as ChatFile;

    await bob.acceptFile(received);
    await settle();

    expect(received.status, FileStatus.done);
    expect(sent.status, FileStatus.done);
    final sink = disk.sinks.single;
    expect(sink.closed, isTrue);
    expect(sink.aborted, isFalse);
    expect(sink.data.toBytes(), bytes);
    expect(received.saved?.name, 'vidéo.mp4');
    expect(received.transferred, bytes.length);
    expect(sent.transferred, bytes.length);
    expect(sent.progress, 1);
    expect(source.closed, isTrue);
    final chunks = wire.whereType<FileChunkFrame>().map((f) => f.index);
    expect(chunks, List.generate(10, (i) => i));
  });

  test('never more than the window ahead of the receiver', () async {
    final source = FakeChosenFile('gros.bin', content(kFileChunkBytes * 20));
    alice.sendFile(source);
    final received = bob.messages.single as ChatFile;
    await bob.acceptFile(received);
    await settle();
    // Nothing more is sent when the acknowledgements stop coming back.
    holdToBob = true;
    final sentBefore = wire.whereType<FileChunkFrame>().length;
    expect(sentBefore, 20, reason: 'done before holding');

    final second = FakeChosenFile('autre.bin', content(kFileChunkBytes * 20));
    alice.sendFile(second);
    holdToBob = false;
    final offer = wire.last as FileOfferFrame;
    bob.receive(offer);
    holdToBob = true;
    await bob.acceptFile(bob.byId(offer.fid)! as ChatFile);
    await settle();
    final ahead = wire
        .whereType<FileChunkFrame>()
        .where((f) => f.fid == offer.fid)
        .length;
    expect(ahead, kFileWindowChunks);
  });

  test('progress is reported on both sides', () async {
    final bytes = content(kFileChunkBytes * 3);
    final sent = alice.sendFile(FakeChosenFile('a.bin', bytes))!;
    final received = bob.messages.single as ChatFile;
    final seen = <int>[];
    alice.addListener(() => seen.add(sent.transferred));
    await bob.acceptFile(received);
    await settle();
    expect(seen, containsAllInOrder([kFileChunkBytes, kFileChunkBytes * 2]));
    expect(seen.last, bytes.length);
  });

  test('declining tells the sender, and nothing is read', () async {
    final source = FakeChosenFile('secret.zip', content(5000));
    final sent = alice.sendFile(source)!;
    final received = bob.messages.single as ChatFile;

    bob.cancelFile(received);
    await settle();

    expect(received.status, FileStatus.declined);
    expect(sent.status, FileStatus.declined);
    expect(source.reads, isEmpty);
    expect(source.closed, isTrue);
    expect(disk.sinks, isEmpty);
  });

  test('the sender can withdraw an offer', () async {
    final sent = alice.sendFile(FakeChosenFile('a.txt', content(10)))!;
    final received = bob.messages.single as ChatFile;
    alice.cancelFile(sent);
    await settle();
    expect(sent.status, FileStatus.cancelled);
    expect(received.status, FileStatus.cancelled);
    await bob.acceptFile(received);
    expect(disk.sinks, isEmpty, reason: 'a withdrawn offer cannot be taken');
  });

  test('cancelling during the transfer deletes the partial file', () async {
    final source = FakeChosenFile('long.iso', content(kFileChunkBytes * 30));
    final sent = alice.sendFile(source)!;
    final received = bob.messages.single as ChatFile;
    holdToBob = true;
    await bob.acceptFile(received);
    await settle();
    // Let a few chunks through, then the receiver stops.
    for (final frame in heldToBob.take(2).toList()) {
      bob.receive(frame);
    }
    await settle();
    expect(received.status, FileStatus.transferring);
    bob.cancelFile(received);
    await settle();

    expect(received.status, FileStatus.cancelled);
    expect(sent.status, FileStatus.cancelled);
    expect(disk.sinks.single.aborted, isTrue);
    expect(disk.sinks.single.closed, isFalse);
    expect(source.closed, isTrue);
  });

  test('the peer leaving stops the transfer and deletes the part', () async {
    final sent = alice.sendFile(
      FakeChosenFile('x.bin', content(kFileChunkBytes * 30)),
    )!;
    final received = bob.messages.single as ChatFile;
    holdToBob = true;
    await bob.acceptFile(received);
    await settle();

    bob.markPeerLeft();
    alice.markPeerLeft();
    await settle();

    expect(received.status, FileStatus.cancelled);
    expect(sent.status, FileStatus.cancelled);
    expect(disk.sinks.single.aborted, isTrue);
  });

  test('closing the conversation aborts an unfinished download', () async {
    alice.sendFile(FakeChosenFile('x.bin', content(kFileChunkBytes * 30)));
    final received = bob.messages.single as ChatFile;
    holdToBob = true;
    await bob.acceptFile(received);
    await settle();
    final sink = disk.sinks.single;
    bob.dispose();
    await settle();
    expect(sink.aborted, isTrue);
    // tearDown disposes again: make that harmless.
    bob = ChatSession(sid: 's', peer: '1', send: (_) {});
  });

  test('a write error fails the transfer on both sides', () async {
    disk.failWrite = 2;
    final sent = alice.sendFile(
      FakeChosenFile('a.bin', content(kFileChunkBytes * 5)),
    )!;
    final received = bob.messages.single as ChatFile;
    await bob.acceptFile(received);
    await settle();

    expect(received.status, FileStatus.failed);
    expect(received.error, 'Disque plein.');
    expect(sent.status, FileStatus.cancelled);
    expect(disk.sinks.single.aborted, isTrue);
  });

  test('no Downloads folder: the transfer fails before starting', () async {
    disk.createError = 'Dossier Téléchargements introuvable.';
    final source = FakeChosenFile('a.bin', content(100));
    final sent = alice.sendFile(source)!;
    final received = bob.messages.single as ChatFile;
    await bob.acceptFile(received);
    await settle();
    expect(received.status, FileStatus.failed);
    expect(received.error, contains('introuvable'));
    expect(sent.status, FileStatus.declined);
    expect(source.reads, isEmpty);
  });

  test('a read error on the sender side fails the transfer', () async {
    final source = FakeChosenFile('a.bin', content(kFileChunkBytes * 3))
      ..failAt = kFileChunkBytes;
    final sent = alice.sendFile(source)!;
    final received = bob.messages.single as ChatFile;
    await bob.acceptFile(received);
    await settle();
    expect(sent.status, FileStatus.failed);
    expect(sent.error, 'Fichier introuvable.');
    expect(received.status, FileStatus.cancelled);
    expect(disk.sinks.single.aborted, isTrue);
  });

  test('an empty file is created right away', () async {
    final sent = alice.sendFile(FakeChosenFile('vide.txt', Uint8List(0)))!;
    final received = bob.messages.single as ChatFile;
    await bob.acceptFile(received);
    await settle();
    expect(received.status, FileStatus.done);
    expect(sent.status, FileStatus.done);
    expect(disk.sinks.single.closed, isTrue);
    expect(wire.whereType<FileChunkFrame>(), isEmpty);
  });

  test('a file over the limit is not offered', () {
    final big = FakeChosenFile('big', Uint8List(1), size: kMaxFileBytes + 1);
    expect(alice.sendFile(big), isNull);
    expect(wire, isEmpty);
  });

  test('the received name cannot point outside the downloads', () async {
    bob.receive(
      const FileOfferFrame(
        sid: 's',
        fid: '0011223344556677',
        name: r'..\..\Windows\evil.bat',
        size: 3,
      ),
    );
    final received = bob.messages.single as ChatFile;
    expect(received.name, 'evil.bat');
  });

  test('unsolicited or out-of-order chunks are refused', () async {
    bob.receive(
      const FileOfferFrame(
        sid: 's',
        fid: '0011223344556677',
        name: 'a',
        size: 9,
      ),
    );
    final received = bob.messages.single as ChatFile;
    // Not accepted yet: ignored.
    bob.receive(
      const FileChunkFrame(
        sid: 's',
        fid: '0011223344556677',
        index: 0,
        data: 'AAAAAAAAAAAA',
      ),
    );
    expect(disk.sinks, isEmpty);
    expect(received.status, FileStatus.awaiting);

    await bob.acceptFile(received);
    // Wrong length for a 9-byte file (base64 of 3 bytes).
    bob.receive(
      const FileChunkFrame(
        sid: 's',
        fid: '0011223344556677',
        index: 0,
        data: 'AAAA',
      ),
    );
    await settle();
    expect(received.status, FileStatus.failed);
    expect(disk.sinks.single.aborted, isTrue);
    expect(wire.last, isA<FileCancelFrame>());
  });

  test('an acceptance or ack for a file I did not offer is ignored', () {
    bob.receive(
      const FileOfferFrame(
        sid: 's',
        fid: '0011223344556677',
        name: 'a',
        size: 9,
      ),
    );
    final received = bob.messages.single as ChatFile;
    bob.receive(const FileAcceptFrame(sid: 's', fid: '0011223344556677'));
    bob.receive(
      const FileAckFrame(sid: 's', fid: '0011223344556677', count: 1),
    );
    expect(received.status, FileStatus.awaiting);
    expect(wire, isEmpty);
  });

  test('a duplicate offer is ignored', () {
    const offer = FileOfferFrame(
      sid: 's',
      fid: '0011223344556677',
      name: 'a',
      size: 9,
    );
    bob
      ..receive(offer)
      ..receive(offer);
    expect(bob.messages, hasLength(1));
  });

  test('a file can answer a message, and counts as unread', () {
    alice.updateDraft('Tu as le document ?');
    alice.sendMessage();
    final question = bob.messages.single;
    expect(bob.unread, 1);
    bob.sendFile(FakeChosenFile('doc.pdf', content(10)), replyTo: question);
    final offer = wire.whereType<FileOfferFrame>().single;
    expect(offer.reply, question.id);
    expect((alice.messages.last as ChatFile).replyTo, question.id);
    expect(alice.unread, 1);
  });
}
