import 'dart:async';
import 'dart:io';

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

  Future<TestClient> register(String id, [String? secret]) async {
    this.id = id;
    this.secret = secret ?? DismessageId.generateSecret();
    send(RegisterFrame(id: id, secret: this.secret));
    await expectNext<RegisteredFrame>();
    return this;
  }

  Future<void> close() => channel.sink.close();
}

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

  /// Connects A and B and returns the session id.
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
    return startedA.sid;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dismessage_test');
    relay = await relayWithFileStore('${tmp.path}/ids.json');
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
      final a = await (await client()).register(idA, 'secret-a');
      await a.close();
      await server.close(force: true);
      relay = await relayWithFileStore('${tmp.path}/ids.json');
      server = await serve(relay, address: 'localhost', port: 0);
      final intruder = await client();
      intruder.send(const RegisterFrame(id: idA, secret: 'other'));
      await intruder.expectNext<IdTakenFrame>();
      final owner = await client();
      await owner.register(idA, 'secret-a');
    });

    test('secret is never stored in clear', () async {
      await (await client()).register(idA, 'very-secret-value');
      final content = await File('${tmp.path}/ids.json').readAsString();
      expect(content, isNot(contains('very-secret-value')));
      expect(content, contains(idA));
    });

    test('release frees the ID for others', () async {
      final a = await (await client()).register(idA, 'secret-a');
      a.send(const ReleaseFrame(id: idA, secret: 'secret-a'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(relay.onlineCount, 0);
      final b = await client();
      await b.register(idA, 'secret-b');
    });

    test('release with a wrong secret does nothing', () async {
      final a = await (await client()).register(idA, 'secret-a');
      a.send(const ReleaseFrame(id: idA, secret: 'wrong'));
      final b = await client();
      b.send(const RegisterFrame(id: idA, secret: 'secret-b'));
      await b.expectNext<IdTakenFrame>();
    });

    test('newest connection with the same ID wins', () async {
      await (await client()).register(idA, 'secret-a');
      final second = await client();
      await second.register(idA, 'secret-a');
      expect(relay.onlineCount, 1);
      final b = await (await client()).register(idB);
      b.send(const ConnectRequestFrame(to: idA));
      await second.expectNext<IncomingRequestFrame>();
    });
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

      a.send(
        DraftOpsFrame(
          sid: sid,
          seq: 1,
          ops: const [EditOp(pos: 0, del: 0, ins: 'Bon')],
        ),
      );
      a.send(DraftSnapshotFrame(sid: sid, seq: 2, text: 'Bonjour'));
      a.send(
        MessageCommitFrame(
          sid: sid,
          seq: 3,
          text: 'Bonjour\nà toi',
          mid: 'aaaabbbbccccdddd',
        ),
      );
      expect((await b.expectNext<DraftOpsFrame>()).ops.single.ins, 'Bon');
      expect((await b.expectNext<DraftSnapshotFrame>()).text, 'Bonjour');
      final commit = await b.expectNext<MessageCommitFrame>();
      expect(commit.text, 'Bonjour\nà toi');
      expect(commit.mid, 'aaaabbbbccccdddd');

      b.send(DraftResyncFrame(sid: sid));
      await a.expectNext<DraftResyncFrame>();
      await c.expectSilence();
    });

    test('images: offer, request and full data reach the peer only', () async {
      final a = await (await client()).register(idA);
      final b = await (await client()).register(idB);
      final c = await (await client()).register(idC);
      final sid = await pair(a, b);
      const img = '0123456789abcdef';

      a.send(
        ImageOfferFrame(
          sid: sid,
          img: img,
          width: 800,
          height: 600,
          preview: 'AAAA',
        ),
      );
      expect((await b.expectNext<ImageOfferFrame>()).width, 800);
      b.send(ImageRequestFrame(sid: sid, img: img));
      await a.expectNext<ImageRequestFrame>();

      // Close to the maximum size: must go through in one frame.
      final data = 'A' * (kMaxImageDataLength - 4);
      a.send(ImageDataFrame(sid: sid, img: img, data: data));
      expect((await b.expectNext<ImageDataFrame>()).data.length, data.length);
      await c.expectSilence();
    });

    test('replies, reactions and voice reach the peer only', () async {
      final a = await (await client()).register(idA);
      final b = await (await client()).register(idB);
      final c = await (await client()).register(idC);
      final sid = await pair(a, b);
      const first = 'aaaabbbbccccdddd';

      a.send(MessageCommitFrame(sid: sid, seq: 1, text: 'Salut', mid: first));
      await b.expectNext<MessageCommitFrame>();
      b.send(
        MessageCommitFrame(
          sid: sid,
          seq: 1,
          text: 'Re',
          mid: '1111222233334444',
          reply: first,
        ),
      );
      expect((await a.expectNext<MessageCommitFrame>()).reply, first);

      b.send(ReactionFrame(sid: sid, ref: first, emoji: '👍'));
      final reaction = await a.expectNext<ReactionFrame>();
      expect((reaction.ref, reaction.emoji), (first, '👍'));

      // Close to the maximum size: must go through in one frame.
      final data = 'A' * (kMaxVoiceDataLength - 4);
      a.send(
        VoiceFrame(
          sid: sid,
          mid: '9999888877776666',
          durationMs: 3000,
          mime: 'audio/mp4',
          data: data,
          reply: first,
        ),
      );
      final voice = await b.expectNext<VoiceFrame>();
      expect(voice.data.length, data.length);
      expect(voice.durationMs, 3000);
      await c.expectSilence();
    });

    test('a third party cannot inject into a session', () async {
      final a = await (await client()).register(idA);
      final b = await (await client()).register(idB);
      final c = await (await client()).register(idC);
      final sid = await pair(a, b);
      c.send(
        MessageCommitFrame(
          sid: sid,
          seq: 1,
          text: 'pirate',
          mid: 'aaaabbbbccccdddd',
        ),
      );
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
      await (await client()).register(idB, 'secret-b');
      a.send(const PresenceWatchFrame(ids: [idB]));
      expect((await a.expectNext<PresenceFrame>()).online, isTrue);
      await (await client()).register(idB, 'secret-b');
      await a.expectSilence();
    });

    test('releasing an ID shows it offline', () async {
      final a = await (await client()).register(idA);
      final b = await (await client()).register(idB, 'secret-b');
      a.send(const PresenceWatchFrame(ids: [idB]));
      await a.expectNext<PresenceFrame>();
      b.send(const ReleaseFrame(id: idB, secret: 'secret-b'));
      expect((await a.expectNext<PresenceFrame>()).online, isFalse);
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
    final logServer = await serve(logged, address: 'localhost', port: 0);
    addTearDown(() => logServer.close(force: true));
    final a = await TestClient.connect(logServer.port);
    final b = await TestClient.connect(logServer.port);
    clients.addAll([a, b]);
    await a.register(idA, 'top-secret-a');
    await b.register(idB, 'top-secret-b');
    a.send(const ConnectRequestFrame(to: idB));
    await b.expectNext<IncomingRequestFrame>();
    await a.close();
    await b.expectNext<ConnectCancelFrame>();

    final log = lines.join('\n');
    expect(log, contains('+ connexion'));
    expect(log, contains('111 111 111 en ligne'));
    expect(log, contains('demande 111 111 111 → 222 222 222'));
    expect(log, contains('- déconnexion 111 111 111'));
    expect(log, isNot(contains('top-secret')));
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
