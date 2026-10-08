import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:async/async.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:dismessage_server/dismessage_server.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const timeout = Duration(seconds: 3);

class TestClient {
  TestClient._(this.channel)
    : frames = StreamQueue(channel.stream.map(Frame.decode));

  static Future<TestClient> connect(int port) async {
    final channel = WebSocketChannel.connect(
      Uri.parse('ws://localhost:$port/ws'),
    );
    await channel.ready;
    return TestClient._(channel);
  }

  final WebSocketChannel channel;
  final StreamQueue<Frame> frames;
  late final String id;
  late final String secret;

  void send(Frame frame) => channel.sink.add(frame.encode());

  Future<T> expectNext<T extends Frame>() async {
    final frame = await frames.next.timeout(timeout);
    expect(frame, isA<T>());
    return frame as T;
  }

  /// Asserts that nothing arrives within a short delay.
  Future<void> expectSilence() async {
    final got = await Future.any<Object?>([
      frames.peek,
      Future<Object?>.delayed(const Duration(milliseconds: 200)),
    ]);
    expect(got, isNull, reason: 'unexpected frame $got');
  }

  /// Registers [id] with [secret], by default the one the relay signs.
  Future<TestClient> register(String id, [String? secret]) async {
    this.id = id;
    this.secret = secret ?? signer.sign(id);
    send(RegisterFrame(id: id, secret: this.secret));
    await expectNext<RegisteredFrame>();
    return this;
  }

  /// Asks the relay for a new ID, then registers it.
  Future<TestClient> registerNew() async {
    send(const IdRequestFrame());
    final assigned = await expectNext<IdAssignedFrame>();
    return register(assigned.id, assigned.secret);
  }

  /// End-to-end encryption of each conversation, keyed by sid.
  final Map<String, E2eSession> e2e = {};

  /// Seals [frame] for its conversation and sends it.
  Future<void> sendSecure(RelayedFrame frame) async =>
      send(await e2e[frame.sid]!.seal(frame));

  /// The next frame must be sealed: returns it opened.
  Future<T> expectSecure<T extends RelayedFrame>() async {
    final sealed = await expectNext<SealedFrame>();
    final frame = await e2e[sealed.sid]!.open(sealed);
    expect(frame, isA<T>());
    return frame as T;
  }

  Future<void> close() => channel.sink.close();
}

/// Signer of the relay under test (the clients' default secrets).
late IdSigner signer;

const idA = '111111111';
const idB = '222222222';
const idC = '333333333';

void main() {
  late HttpServer server;
  late Relay relay;
  late Directory tmp;
  final clients = <TestClient>[];

  Future<TestClient> client() async {
    final c = await TestClient.connect(server.port);
    clients.add(c);
    return c;
  }

  /// Key exchange through the relay, as the app does at session start.
  Future<void> secure(TestClient a, TestClient b, String sid) async {
    final ea = a.e2e[sid] = E2eSession(sid);
    final eb = b.e2e[sid] = E2eSession(sid);
    a.send(await ea.offer());
    b.send(await eb.offer());
    await eb.accept(await b.expectNext<KeyOfferFrame>());
    await ea.accept(await a.expectNext<KeyOfferFrame>());
  }

  /// Connects A and B (keys exchanged) and returns the session id.
  Future<String> pair(TestClient a, TestClient b) async {
    a.send(ConnectRequestFrame(to: b.id));
    final incoming = await b.expectNext<IncomingRequestFrame>();
    expect(incoming.from, a.id);
    b.send(ConnectAcceptFrame(from: a.id));
    final startedA = await a.expectNext<SessionStartedFrame>();
    final startedB = await b.expectNext<SessionStartedFrame>();
    expect(startedA.peer, b.id);
    expect(startedB.peer, a.id);
    expect(startedA.sid, startedB.sid);
    await secure(a, b, startedA.sid);
    return startedA.sid;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dismessage_test');
    relay = await relayWithFileStore('${tmp.path}/ids.json');
    signer = relay.signer;
    server = await serve(relay, address: 'localhost', port: 0);
  });

  tearDown(() async {
    for (final c in clients) {
      await c.close();
    }
    clients.clear();
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  group('registration', () {
    test('registers a free ID', () async {
      final a = await client();
      await a.register(idA);
      expect(relay.onlineCount, 1);
    });

    test('ID owned by another secret is refused', () async {
      final a = await (await client()).register(idA);
      await a.close();
      final b = await client();
      b.send(const RegisterFrame(id: idA, secret: 'another-secret'));
      expect((await b.expectNext<IdTakenFrame>()).id, idA);
    });

    test('same secret can re-register (stable ID across restarts)', () async {
      final a = await (await client()).register(idA);
      await a.close();
      final again = await client();
      await again.register(idA, a.secret);
    });

    test('ID ownership survives a server restart', () async {
      final a = await (await client()).register(idA);
      await a.close();
      await server.close(force: true);
      relay = await relayWithFileStore('${tmp.path}/ids.json');
      server = await serve(relay, address: 'localhost', port: 0);
      final intruder = await client();
      intruder.send(const RegisterFrame(id: idA, secret: 'other'));
      await intruder.expectNext<IdTakenFrame>();
      final owner = await client();
      await owner.register(idA, a.secret);
    });

    test('a signed ID survives a restart that loses the store', () async {
      final a = await (await client()).registerNew();
      await a.close();
      await server.close(force: true);
      // Render Free: no disk, ids.json is gone. The key stays.
      await File('${tmp.path}/ids.json').delete();
      relay = await relayWithFileStore('${tmp.path}/ids.json');
      server = await serve(relay, address: 'localhost', port: 0);
      final intruder = await client();
      intruder.send(RegisterFrame(id: a.id, secret: 'forged'));
      expect(
        (await intruder.expectNext<ErrorFrame>()).code,
        ErrorCodes.unsignedId,
      );
      expect(relay.onlineCount, 0);
      await (await client()).register(a.id, a.secret);
    });

    test('a secret signed with another key is refused', () async {
      final other = IdSigner.random();
      final a = await client();
      a.send(RegisterFrame(id: idA, secret: other.sign(idA)));
      expect((await a.expectNext<ErrorFrame>()).code, ErrorCodes.unsignedId);
    });

    test('secret and key are never stored in the ID file', () async {
      final a = await (await client()).register(idA);
      final content = await File('${tmp.path}/ids.json').readAsString();
      expect(content, isNot(contains(a.secret)));
      expect(content, contains(idA));
      final key = await File('${tmp.path}/id_key').readAsString();
      expect(content, isNot(contains(key.trim())));
    });

    test('release forgets the ID', () async {
      final a = await (await client()).register(idA);
      a.send(ReleaseFrame(id: idA, secret: a.secret));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(relay.onlineCount, 0);
    });

    test('release with a wrong secret does nothing', () async {
      final a = await (await client()).register(idA);
      a.send(const ReleaseFrame(id: idA, secret: 'wrong'));
      final b = await client();
      b.send(const RegisterFrame(id: idA, secret: 'secret-b'));
      await b.expectNext<IdTakenFrame>();
      expect(relay.onlineCount, 1);
    });

    test('newest connection with the same ID wins', () async {
      await (await client()).register(idA);
      final second = await client();
      await second.register(idA);
      expect(relay.onlineCount, 1);
      final b = await (await client()).register(idB);
      b.send(const ConnectRequestFrame(to: idA));
      await second.expectNext<IncomingRequestFrame>();
    });
  });

  group('assigned IDs', () {
    test('id_request gives a valid ID whose secret registers', () async {
      final a = await client();
      a.send(const IdRequestFrame());
      final assigned = await a.expectNext<IdAssignedFrame>();
      expect(DismessageId.isValid(assigned.id), isTrue);
      expect(signer.verify(assigned.id, assigned.secret), isTrue);
      await a.register(assigned.id, assigned.secret);
      expect(relay.onlineCount, 1);
    });

    test('never hands out an ID that is online or known', () async {
      await server.close(force: true);
      // The relay draws its IDs from this sequence: the first two are taken.
      final draws = Random(7);
      final first = DismessageId.generate(draws);
      final second = DismessageId.generate(draws);
      final third = DismessageId.generate(draws);
      relay = Relay(IdStore.memory(), random: Random(7));
      signer = relay.signer;
      server = await serve(relay, address: 'localhost', port: 0);
      await (await client()).register(first);
      final known = await (await client()).register(second);
      await known.close();
      final c = await client();
      c.send(const IdRequestFrame());
      expect((await c.expectNext<IdAssignedFrame>()).id, third);
    });

    test('an unsigned secret for an unknown ID is refused', () async {
      final a = await client();
      a.send(const RegisterFrame(id: idA, secret: 'chosen-by-me'));
      final error = await a.expectNext<ErrorFrame>();
      expect(error.code, ErrorCodes.unsignedId);
      expect(error.message, contains('nouvelle'));
      expect(relay.onlineCount, 0);
    });

    test('regenerating: new ID, then the old one released', () async {
      final a = await (await client()).register(idA);
      a.send(const IdRequestFrame());
      final assigned = await a.expectNext<IdAssignedFrame>();
      a.send(RegisterFrame(id: assigned.id, secret: assigned.secret));
      await a.expectNext<RegisteredFrame>();
      a.send(ReleaseFrame(id: idA, secret: a.secret));
      final b = await (await client()).register(idB);
      b.send(const ConnectRequestFrame(to: idA));
      await b.expectNext<PeerOfflineFrame>();
      b.send(ConnectRequestFrame(to: assigned.id));
      await a.expectNext<IncomingRequestFrame>();
    });

    group('older clients (transition)', () {
      Future<void> restart({
        required bool legacy,
        bool keepStore = true,
      }) async {
        await server.close(force: true);
        if (!keepStore) await File('${tmp.path}/ids.json').delete();
        relay = await relayWithFileStore(
          '${tmp.path}/ids.json',
          acceptLegacyIds: legacy,
        );
        signer = relay.signer;
        server = await serve(relay, address: 'localhost', port: 0);
      }

      test('accepted: first come, then upgraded to a signed secret', () async {
        await restart(legacy: true);
        final a = await client();
        a.send(const RegisterFrame(id: idA, secret: 'my-own-secret'));
        final assigned = await a.expectNext<IdAssignedFrame>();
        expect(assigned.id, idA);
        expect(signer.verify(idA, assigned.secret), isTrue);
        await a.expectNext<RegisteredFrame>();
        // The signed secret keeps the same ID once the store is lost.
        await a.close();
        await restart(legacy: false, keepStore: false);
        await (await client()).register(idA, assigned.secret);
      });

      test(
        'a known older ID is upgraded even when no longer accepted',
        () async {
          await restart(legacy: true);
          final a = await client();
          a.send(const RegisterFrame(id: idA, secret: 'my-own-secret'));
          await a.expectNext<IdAssignedFrame>();
          await a.expectNext<RegisteredFrame>();
          await a.close();
          await restart(legacy: false);
          final again = await client();
          again.send(const RegisterFrame(id: idA, secret: 'my-own-secret'));
          expect((await again.expectNext<IdAssignedFrame>()).id, idA);
          await again.expectNext<RegisteredFrame>();
        },
      );

      test('both secrets work while the store remembers the old one', () async {
        await restart(legacy: true);
        final a = await client();
        a.send(const RegisterFrame(id: idA, secret: 'my-own-secret'));
        final assigned = await a.expectNext<IdAssignedFrame>();
        await a.expectNext<RegisteredFrame>();
        await a.close();
        // An older client ignores id_assigned and comes back with its own.
        final old = await client();
        old.send(const RegisterFrame(id: idA, secret: 'my-own-secret'));
        await old.expectNext<IdAssignedFrame>();
        await old.expectNext<RegisteredFrame>();
        await old.close();
        await (await client()).register(idA, assigned.secret);
        // Anyone else still is refused.
        final intruder = await client();
        intruder.send(const RegisterFrame(id: idA, secret: 'guess'));
        await intruder.expectNext<IdTakenFrame>();
      });
    });
  });

  test('a client older than the minimum version is told to update', () async {
    await server.close(force: true);
    relay = Relay(IdStore.memory(), minProtocolVersion: kProtocolVersion + 1);
    signer = relay.signer;
    server = await serve(relay, address: 'localhost', port: 0);
    final old = await client();
    old.send(RegisterFrame(id: idA, secret: signer.sign(idA)));
    final error = await old.expectNext<ErrorFrame>();
    expect(error.code, ErrorCodes.updateRequired);
    expect(error.message, contains('installez la nouvelle'));
    expect(relay.onlineCount, 0);
    final current = await client();
    current.send(
      RegisterFrame(id: idA, secret: signer.sign(idA), v: kProtocolVersion + 1),
    );
    await current.expectNext<RegisteredFrame>();
  });

  group('ID signer', () {
    test('same key, same secret; another key or ID, another one', () {
      final key = List.filled(32, 7);
      final s = IdSigner(key);
      expect(IdSigner(key).sign(idA), s.sign(idA));
      expect(s.verify(idA, s.sign(idA)), isTrue);
      expect(s.verify(idB, s.sign(idA)), isFalse);
      expect(s.verify(idA, IdSigner(List.filled(32, 8)).sign(idA)), isFalse);
      expect(s.verify(idA, ''), isFalse);
      expect(s.sign(idA).length, lessThanOrEqualTo(kMaxSecretLength));
    });

    test('a short key is refused', () {
      expect(() => IdSigner(List.filled(16, 1)), throwsArgumentError);
    });

    test(
      'key from the environment, else from a file kept across starts',
      () async {
        final file = File('${tmp.path}/keys/id_key');
        final fromEnv = await IdSigner.load(fromEnv: 'a' * 40, file: file);
        expect(fromEnv.usesFile, isFalse);
        expect(file.existsSync(), isFalse);
        expect(fromEnv.sign(idA), IdSigner(List.filled(40, 0x61)).sign(idA));

        final first = await IdSigner.load(file: file);
        final second = await IdSigner.load(file: file);
        expect(first.usesFile, isTrue);
        expect(second.sign(idA), first.sign(idA));
      },
    );
  });

  group('pairing', () {
    test('request to an offline peer', () async {
      final a = await (await client()).register(idA);
      a.send(const ConnectRequestFrame(to: idB));
      expect((await a.expectNext<PeerOfflineFrame>()).peer, idB);
    });

    test('requires registration', () async {
      final a = await client();
      a.send(const ConnectRequestFrame(to: idB));
      expect((await a.expectNext<ErrorFrame>()).code, 'not_registered');
    });

    test('cannot connect to yourself', () async {
      final a = await (await client()).register(idA);
      a.send(const ConnectRequestFrame(to: idA));
      expect((await a.expectNext<ErrorFrame>()).code, 'self_connect');
    });

    test('accept starts a session', () async {
      final a = await (await client()).register(idA);
      final b = await (await client()).register(idB);
      await pair(a, b);
      expect(relay.sessionCount, 1);
    });

    test('reject notifies the requester', () async {
      final a = await (await client()).register(idA);
      final b = await (await client()).register(idB);
      a.send(const ConnectRequestFrame(to: idB));
      await b.expectNext<IncomingRequestFrame>();
      b.send(const ConnectRejectFrame(peer: idA));
      expect((await a.expectNext<ConnectRejectFrame>()).peer, idB);
      expect(relay.sessionCount, 0);
    });

    test('cancel closes the request on the target side', () async {
      final a = await (await client()).register(idA);
      final b = await (await client()).register(idB);
      a.send(const ConnectRequestFrame(to: idB));
      await b.expectNext<IncomingRequestFrame>();
      a.send(const ConnectCancelFrame(peer: idB));
      expect((await b.expectNext<ConnectCancelFrame>()).peer, idA);
      b.send(const ConnectAcceptFrame(from: idA));
      expect((await b.expectNext<ErrorFrame>()).code, 'no_request');
      await a.expectSilence();
    });

    test('requester disconnecting withdraws its request', () async {
      final a = await (await client()).register(idA);
      final b = await (await client()).register(idB);
      a.send(const ConnectRequestFrame(to: idB));
      await b.expectNext<IncomingRequestFrame>();
      await a.close();
      expect((await b.expectNext<ConnectCancelFrame>()).peer, idA);
    });

    test(
      'target disconnecting answers peer_offline to the requester',
      () async {
        final a = await (await client()).register(idA);
        final b = await (await client()).register(idB);
        a.send(const ConnectRequestFrame(to: idB));
        await b.expectNext<IncomingRequestFrame>();
        await b.close();
        expect((await a.expectNext<PeerOfflineFrame>()).peer, idB);
      },
    );

    test('cancelling an unknown request does nothing', () async {
      final a = await (await client()).register(idA);
      final b = await (await client()).register(idB);
      a.send(const ConnectCancelFrame(peer: idB));
      await b.expectSilence();
    });

    test('accept without a request is refused', () async {
      final a = await (await client()).register(idA);
      await (await client()).register(idB);
      a.send(const ConnectAcceptFrame(from: idB));
      expect((await a.expectNext<ErrorFrame>()).code, 'no_request');
    });
  });

  group('relay', () {
    test('draft and commit frames reach the peer only', () async {
      final a = await (await client()).register(idA);
      final b = await (await client()).register(idB);
      final c = await (await client()).register(idC);
      final sid = await pair(a, b);

      await a.sendSecure(
        DraftOpsFrame(
          sid: sid,
          seq: 1,
          ops: const [EditOp(pos: 0, del: 0, ins: 'Bon')],
        ),
      );
      await a.sendSecure(DraftSnapshotFrame(sid: sid, seq: 2, text: 'Bonjour'));
      await a.sendSecure(
        MessageCommitFrame(
          sid: sid,
          seq: 3,
          text: 'Bonjour\nà toi',
          mid: 'aaaabbbbccccdddd',
        ),
      );
      expect((await b.expectSecure<DraftOpsFrame>()).ops.single.ins, 'Bon');
      expect((await b.expectSecure<DraftSnapshotFrame>()).text, 'Bonjour');
      final commit = await b.expectSecure<MessageCommitFrame>();
      expect(commit.text, 'Bonjour\nà toi');
      expect(commit.mid, 'aaaabbbbccccdddd');

      await b.sendSecure(DraftResyncFrame(sid: sid));
      await a.expectSecure<DraftResyncFrame>();
      await c.expectSilence();
    });

    test('images: offer, request and full data reach the peer only', () async {
      final a = await (await client()).register(idA);
      final b = await (await client()).register(idB);
      final c = await (await client()).register(idC);
      final sid = await pair(a, b);
      const img = '0123456789abcdef';

      await a.sendSecure(
        ImageOfferFrame(
          sid: sid,
          img: img,
          width: 800,
          height: 600,
          preview: 'AAAA',
        ),
      );
      expect((await b.expectSecure<ImageOfferFrame>()).width, 800);
      await b.sendSecure(ImageRequestFrame(sid: sid, img: img));
      await a.expectSecure<ImageRequestFrame>();

      // Close to the maximum size: must go through in one frame.
      final data = 'A' * (kMaxImageDataLength - 4);
      await a.sendSecure(ImageDataFrame(sid: sid, img: img, data: data));
      expect((await b.expectSecure<ImageDataFrame>()).data.length, data.length);
      await c.expectSilence();
    });

    test('replies, reactions and voice reach the peer only', () async {
      final a = await (await client()).register(idA);
      final b = await (await client()).register(idB);
      final c = await (await client()).register(idC);
      final sid = await pair(a, b);
      const first = 'aaaabbbbccccdddd';

      await a.sendSecure(
        MessageCommitFrame(sid: sid, seq: 1, text: 'Salut', mid: first),
      );
      await b.expectSecure<MessageCommitFrame>();
      await b.sendSecure(
        MessageCommitFrame(
          sid: sid,
          seq: 1,
          text: 'Re',
          mid: '1111222233334444',
          reply: first,
        ),
      );
      expect((await a.expectSecure<MessageCommitFrame>()).reply, first);

      await b.sendSecure(ReactionFrame(sid: sid, ref: first, emoji: '👍'));
      final reaction = await a.expectSecure<ReactionFrame>();
      expect((reaction.ref, reaction.emoji), (first, '👍'));

      // Close to the maximum size: must go through in one frame.
      final data = 'A' * (kMaxVoiceDataLength - 4);
      await a.sendSecure(
        VoiceFrame(
          sid: sid,
          mid: '9999888877776666',
          durationMs: 3000,
          mime: 'audio/mp4',
          data: data,
          reply: first,
        ),
      );
      final voice = await b.expectSecure<VoiceFrame>();
      expect(voice.data.length, data.length);
      expect(voice.durationMs, 3000);
      await c.expectSilence();
    });

    test(
      'files: offer, accept, chunks, acks and cancel reach the peer only',
      () async {
        final a = await (await client()).register(idA);
        final b = await (await client()).register(idB);
        final c = await (await client()).register(idC);
        final sid = await pair(a, b);
        const fid = '0011223344556677';

        await a.sendSecure(
          FileOfferFrame(sid: sid, fid: fid, name: 'notes.pdf', size: 300000),
        );
        final offer = await b.expectSecure<FileOfferFrame>();
        expect((offer.name, offer.size), ('notes.pdf', 300000));

        await b.sendSecure(FileAcceptFrame(sid: sid, fid: fid));
        await a.expectSecure<FileAcceptFrame>();

        // A full chunk goes through in one frame.
        final data = 'A' * kMaxFileChunkDataLength;
        await a.sendSecure(
          FileChunkFrame(sid: sid, fid: fid, index: 0, data: data),
        );
        final chunk = await b.expectSecure<FileChunkFrame>();
        expect((chunk.index, chunk.data.length), (0, data.length));

        await b.sendSecure(FileAckFrame(sid: sid, fid: fid, count: 1));
        expect((await a.expectSecure<FileAckFrame>()).count, 1);

        await b.sendSecure(FileCancelFrame(sid: sid, fid: fid));
        await a.expectSecure<FileCancelFrame>();
        await c.expectSilence();
      },
    );

    test('an unencrypted conversation frame is refused', () async {
      final a = await (await client()).register(idA);
      final b = await (await client()).register(idB);
      final sid = await pair(a, b);
      a.send(
        MessageCommitFrame(
          sid: sid,
          seq: 1,
          text: 'en clair',
          mid: 'aaaabbbbccccdddd',
        ),
      );
      expect((await a.expectNext<ErrorFrame>()).code, 'unencrypted');
      await b.expectSilence();
    });

    test('the relay passes on what it cannot read', () async {
      final a = await (await client()).register(idA);
      final b = await (await client()).register(idB);
      final sid = await pair(a, b);
      final raw = <String>[];
      // What B receives on the wire, before opening it.
      await a.sendSecure(
        MessageCommitFrame(
          sid: sid,
          seq: 1,
          text: 'Rendez-vous à 18 h',
          mid: 'aaaabbbbccccdddd',
        ),
      );
      final sealed = await b.expectNext<SealedFrame>();
      raw.add(sealed.encode());
      expect(raw.single, isNot(contains('Rendez-vous')));
      final opened = await b.e2e[sid]!.open(sealed) as MessageCommitFrame;
      expect(opened.text, 'Rendez-vous à 18 h');
    });

    test('a third party cannot inject into a session', () async {
      final a = await (await client()).register(idA);
      final b = await (await client()).register(idB);
      final c = await (await client()).register(idC);
      final sid = await pair(a, b);
      // C has no key for it anyway: a forged sealed frame.
      c.send(SealedFrame(sid: sid, n: 1, data: 'cGlyYXRl'));
      expect((await c.expectNext<ErrorFrame>()).code, 'unknown_session');
      await a.expectSilence();
      await b.expectSilence();
    });

    test('session_leave sends peer_left and ends the session', () async {
      final a = await (await client()).register(idA);
      final b = await (await client()).register(idB);
      final sid = await pair(a, b);
      a.send(SessionLeaveFrame(sid: sid));
      expect((await b.expectNext<PeerLeftFrame>()).sid, sid);
      expect(relay.sessionCount, 0);
      expect(relay.onlineCount, 2, reason: 'both stay online');
    });

    test('one client in two sessions at once, each isolated', () async {
      final a = await (await client()).register(idA);
      final b = await (await client()).register(idB);
      final c = await (await client()).register(idC);
      final withB = await pair(a, b);
      final withC = await pair(a, c);
      expect(withC, isNot(withB));
      expect(relay.sessionCount, 2);

      await a.sendSecure(
        DraftSnapshotFrame(sid: withB, seq: 1, text: 'pour B'),
      );
      expect((await b.expectSecure<DraftSnapshotFrame>()).text, 'pour B');
      await c.expectSilence();
      await c.sendSecure(DraftSnapshotFrame(sid: withC, seq: 1, text: 'de C'));
      final fromC = await a.expectSecure<DraftSnapshotFrame>();
      expect(fromC.sid, withC);
      expect(fromC.text, 'de C');

      a.send(SessionLeaveFrame(sid: withB));
      expect((await b.expectNext<PeerLeftFrame>()).sid, withB);
      await c.expectSilence();
      expect(relay.sessionCount, 1);
    });

    test('disconnect sends peer_left and ends the session', () async {
      final a = await (await client()).register(idA);
      final b = await (await client()).register(idB);
      final sid = await pair(a, b);
      await a.close();
      expect((await b.expectNext<PeerLeftFrame>()).sid, sid);
      expect(relay.sessionCount, 0);
    });
  });

  group('presence', () {
    test('watching reports the current state of each ID', () async {
      final a = await (await client()).register(idA);
      await (await client()).register(idB);
      a.send(const PresenceWatchFrame(ids: [idB, idC]));
      final b = await a.expectNext<PresenceFrame>();
      final c = await a.expectNext<PresenceFrame>();
      expect((b.id, b.online), (idB, true));
      expect((c.id, c.online), (idC, false));
    });

    test('watchers learn when an ID comes and goes', () async {
      final a = await (await client()).register(idA);
      a.send(const PresenceWatchFrame(ids: [idB]));
      expect((await a.expectNext<PresenceFrame>()).online, isFalse);

      final b = await (await client()).register(idB);
      final online = await a.expectNext<PresenceFrame>();
      expect((online.id, online.online), (idB, true));

      await b.close();
      final offline = await a.expectNext<PresenceFrame>();
      expect((offline.id, offline.online), (idB, false));
    });

    test('a new watch list replaces the previous one', () async {
      final a = await (await client()).register(idA);
      a.send(const PresenceWatchFrame(ids: [idB]));
      await a.expectNext<PresenceFrame>();
      a.send(const PresenceWatchFrame(ids: []));
      await (await client()).register(idB);
      await a.expectSilence();
    });

    test('reconnecting elsewhere does not flicker offline', () async {
      final a = await (await client()).register(idA);
      await (await client()).register(idB);
      a.send(const PresenceWatchFrame(ids: [idB]));
      expect((await a.expectNext<PresenceFrame>()).online, isTrue);
      await (await client()).register(idB);
      await a.expectSilence();
    });

    test('releasing an ID shows it offline', () async {
      final a = await (await client()).register(idA);
      final b = await (await client()).register(idB);
      a.send(const PresenceWatchFrame(ids: [idB]));
      await a.expectNext<PresenceFrame>();
      b.send(ReleaseFrame(id: idB, secret: b.secret));
      expect((await a.expectNext<PresenceFrame>()).online, isFalse);
    });

    test('a client that stops answering pings goes offline', () async {
      // Short ping interval for this test only.
      await server.close(force: true);
      server = await serve(
        relay,
        address: 'localhost',
        port: 0,
        pingInterval: const Duration(milliseconds: 300),
      );
      final watcher = await (await client()).register(idA);
      watcher.send(const PresenceWatchFrame(ids: [idB]));
      expect((await watcher.expectNext<PresenceFrame>()).online, isFalse);

      // A raw socket: WebSocket handshake, register, then silence (no pong),
      // like a phone that lost its network without closing.
      final ghost = await Socket.connect('localhost', server.port);
      addTearDown(ghost.destroy);
      final handshake = Completer<void>();
      ghost.listen((data) {
        if (!handshake.isCompleted &&
            String.fromCharCodes(data).contains('101')) {
          handshake.complete();
        }
      });
      ghost.write(
        'GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n'
        'Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
        'Sec-WebSocket-Version: 13\r\n\r\n',
      );
      await handshake.future.timeout(timeout);
      ghost.add(
        _maskedText(RegisterFrame(id: idB, secret: signer.sign(idB)).encode()),
      );

      final online = await watcher.expectNext<PresenceFrame>();
      expect((online.id, online.online), (idB, true));
      final offline = await watcher.expectNext<PresenceFrame>();
      expect((offline.id, offline.online), (idB, false));
    });

    test('requires registration', () async {
      final a = await client();
      a.send(const PresenceWatchFrame(ids: [idB]));
      expect((await a.expectNext<ErrorFrame>()).code, 'not_registered');
    });

    test('a disconnected watcher is forgotten', () async {
      final a = await (await client()).register(idA);
      a.send(const PresenceWatchFrame(ids: [idB]));
      await a.expectNext<PresenceFrame>();
      await a.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // Would throw on a closed sink if A were still a watcher.
      await (await client()).register(idB);
      expect(relay.onlineCount, 1);
    });
  });

  test('activity log shows IDs but never secrets', () async {
    final lines = <String>[];
    final logged = Relay(IdStore.memory(), log: lines.add);
    signer = logged.signer;
    final logServer = await serve(logged, address: 'localhost', port: 0);
    addTearDown(() => logServer.close(force: true));
    final a = await TestClient.connect(logServer.port);
    final b = await TestClient.connect(logServer.port);
    clients.addAll([a, b]);
    await a.register(idA);
    await b.register(idB);
    final c = await TestClient.connect(logServer.port);
    clients.add(c);
    await c.registerNew();
    a.send(const ConnectRequestFrame(to: idB));
    await b.expectNext<IncomingRequestFrame>();
    await a.close();
    await b.expectNext<ConnectCancelFrame>();

    final log = lines.join('\n');
    expect(log, contains('+ connexion'));
    expect(log, contains('111 111 111 en ligne'));
    expect(log, contains('demande 111 111 111 → 222 222 222'));
    expect(log, contains('- déconnexion 111 111 111'));
    expect(log, contains('nouvel ID ${DismessageId.format(c.id)} attribué'));
    for (final secret in [a.secret, b.secret, c.secret]) {
      expect(log, isNot(contains(secret)));
    }
  });

  group('rate limits', () {
    var now = DateTime(2026);
    late List<String> lines;

    /// Restarts the relay with [limits] and a clock moved by [advance].
    Future<void> limited(RateLimits limits, {bool realClock = false}) async {
      await server.close(force: true);
      now = DateTime(2026);
      lines = [];
      relay = Relay(
        IdStore.memory(),
        limits: limits,
        clock: realClock ? null : () => now,
        log: lines.add,
      );
      signer = relay.signer;
      server = await serve(relay, address: 'localhost', port: 0);
    }

    void advance(Duration d) => now = now.add(d);

    Future<void> expectLimited(TestClient c) async =>
        expect((await c.expectNext<ErrorFrame>()).code, ErrorCodes.rateLimited);

    RateLimits only({
      int requestsBurst = 1 << 30,
      int ipRequestsBurst = 1 << 30,
      int ipRegistersBurst = 1 << 30,
      int ipNewIdsBurst = 1 << 30,
      int watchesBurst = 1 << 30,
      int connectionsPerIp = 1 << 30,
      int framesBurst = 1 << 30,
      int framesPerSecond = 1 << 30,
    }) => RateLimits(
      framesBurst: framesBurst,
      framesPerSecond: framesPerSecond,
      bytesBurst: 1 << 40,
      bytesPerSecond: 1 << 40,
      requestsBurst: requestsBurst,
      requestsPerMinute: 1,
      ipRequestsBurst: ipRequestsBurst,
      ipRequestsPerMinute: 1,
      ipRegistersBurst: ipRegistersBurst,
      ipRegistersPerMinute: 1,
      ipNewIdsBurst: ipNewIdsBurst,
      ipNewIdsPerHour: 1,
      watchesBurst: watchesBurst,
      watchesPerMinute: 1,
      connectionsPerIp: connectionsPerIp,
    );

    test('chat requests of one connection are limited, then refill', () async {
      await limited(only(requestsBurst: 2));
      final a = await (await client()).register(idA);
      final b = await (await client()).register(idB);
      for (var i = 0; i < 2; i++) {
        a.send(const ConnectRequestFrame(to: idB));
        await b.expectNext<IncomingRequestFrame>();
      }
      a.send(const ConnectRequestFrame(to: idB));
      await expectLimited(a);
      await b.expectSilence();
      // Probing an offline ID costs the same.
      a.send(const ConnectRequestFrame(to: idC));
      await expectLimited(a);

      advance(const Duration(minutes: 1));
      a.send(const ConnectRequestFrame(to: idB));
      await b.expectNext<IncomingRequestFrame>();
      // Logged once per connection, not once per refusal.
      expect(lines.where((l) => l.contains('limite')), hasLength(1));
    });

    test('chat requests are counted per IP across connections', () async {
      await limited(only(ipRequestsBurst: 2));
      final a = await (await client()).register(idA);
      final c = await (await client()).register(idC);
      final b = await (await client()).register(idB);
      a.send(const ConnectRequestFrame(to: idB));
      await b.expectNext<IncomingRequestFrame>();
      c.send(const ConnectRequestFrame(to: idB));
      await b.expectNext<IncomingRequestFrame>();
      a.send(const ConnectRequestFrame(to: idB));
      await expectLimited(a);
    });

    test('new IDs from one IP are limited, owned ones are not', () async {
      await limited(only(ipNewIdsBurst: 1));
      final a = await (await client()).registerNew();
      await a.close();
      final b = await client();
      b.send(const IdRequestFrame());
      await expectLimited(b);
      expect(relay.onlineCount, 0);
      // The owner of an ID still gets back in.
      await (await client()).register(a.id, a.secret);
    });

    test('registrations from one IP are limited', () async {
      await limited(only(ipRegistersBurst: 2));
      final a = await (await client()).register(idA);
      final again = RegisterFrame(id: idA, secret: a.secret);
      a.send(again);
      await a.expectNext<RegisteredFrame>();
      a.send(again);
      await expectLimited(a);
      advance(const Duration(minutes: 1));
      a.send(again);
      await a.expectNext<RegisteredFrame>();
    });

    test('presence lists are limited', () async {
      await limited(only(watchesBurst: 1));
      final a = await (await client()).register(idA);
      a.send(const PresenceWatchFrame(ids: [idB]));
      await a.expectNext<PresenceFrame>();
      a.send(const PresenceWatchFrame(ids: [idC]));
      await expectLimited(a);
    });

    test('too many connections from one IP: the extra one is closed', () async {
      await limited(only(connectionsPerIp: 2));
      await client();
      final second = await client();
      final third = await client();
      expect(
        (await third.expectNext<ErrorFrame>()).code,
        ErrorCodes.tooManyConnections,
      );
      expect(await third.frames.hasNext.timeout(timeout), isFalse);
      await second.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await (await client()).register(idA);
    });

    test('frame throughput is slowed down, never dropped', () async {
      await limited(only(framesBurst: 5, framesPerSecond: 20), realClock: true);
      final a = await client();
      final watch = Stopwatch()..start();
      for (var i = 0; i < 25; i++) {
        a.send(const PingFrame());
      }
      for (var i = 0; i < 25; i++) {
        await a.expectNext<PongFrame>();
      }
      // 20 frames over the burst, at 20 per second.
      expect(watch.elapsedMilliseconds, greaterThan(800));
    });

    test('default limits leave normal use alone', () async {
      await limited(const RateLimits());
      final a = await (await client()).register(idA);
      final b = await (await client()).register(idB);
      final sid = await pair(a, b);
      for (var i = 0; i < 100; i++) {
        await a.sendSecure(
          DraftSnapshotFrame(sid: sid, seq: i + 1, text: 'x' * i),
        );
      }
      for (var i = 0; i < 100; i++) {
        await b.expectSecure<DraftSnapshotFrame>();
      }
    });
  });

  group('client IP', () {
    test('a header set by the proxy wins', () {
      expect(
        clientIp(
          {'cf-connecting-ip': '1.2.3.4', 'x-forwarded-for': '9.9.9.9'},
          '10.0.0.1',
          ipHeader: 'CF-Connecting-IP',
        ),
        '1.2.3.4',
      );
    });

    test(
      'otherwise the last forwarded entry (the earlier ones are forged)',
      () {
        expect(
          clientIp({'x-forwarded-for': '6.6.6.6, 5.6.7.8'}, '10.0.0.1'),
          '5.6.7.8',
        );
        expect(
          clientIp(
            {'x-forwarded-for': '5.6.7.8'},
            '10.0.0.1',
            ipHeader: 'cf-connecting-ip',
          ),
          '5.6.7.8',
        );
      },
    );

    test('otherwise the socket address', () {
      expect(clientIp({}, '10.0.0.1'), '10.0.0.1');
    });
  });

  group('robustness', () {
    test('invalid frames get an error and the connection survives', () async {
      final a = await client();
      a.channel.sink.add('{not json');
      expect((await a.expectNext<ErrorFrame>()).code, 'bad_frame');
      a.channel.sink.add('{"t":"register","id":"0","secret":"x"}');
      expect((await a.expectNext<ErrorFrame>()).code, 'bad_frame');
      await a.register(idA);
    });

    test('server-only frames from a client are refused', () async {
      final a = await client();
      a.send(const RegisteredFrame(id: idA));
      expect((await a.expectNext<ErrorFrame>()).code, 'unexpected_frame');
    });

    test('oversized frames are refused', () async {
      final a = await client();
      a.channel.sink.add('x' * (kMaxRawFrameLength + 1));
      expect((await a.expectNext<ErrorFrame>()).code, 'too_large');
    });

    test('ping gets a pong', () async {
      final a = await client();
      a.send(const PingFrame());
      await a.expectNext<PongFrame>();
    });
  });
}

/// A client-to-server WebSocket text frame (clients must mask), < 64 KiB.
List<int> _maskedText(String text) {
  final payload = text.codeUnits;
  const mask = [1, 2, 3, 4];
  return [
    0x81,
    0x80 | (payload.length < 126 ? payload.length : 126),
    if (payload.length >= 126) ...[payload.length >> 8, payload.length & 0xff],
    ...mask,
    for (var i = 0; i < payload.length; i++) payload[i] ^ mask[i % 4],
  ];
}
