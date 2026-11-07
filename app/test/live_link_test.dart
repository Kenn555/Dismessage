import 'dart:convert';
import 'dart:typed_data';

import 'package:dismessage/services/chat_session.dart';
import 'package:dismessage/services/live_camera.dart';
import 'package:dismessage/services/live_link.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const peer = '318343691';

void main() {
  late List<Frame> sent;
  late FakeLiveCamera camera;
  late int now;
  late List<String> notices;
  ChatSession? current;

  ChatSession newSession({LiveCamera? Function()? createCamera}) {
    sent = [];
    now = 0;
    notices = [];
    camera = FakeLiveCamera();
    final session = current = ChatSession(
      sid: 's1',
      peer: peer,
      send: sent.add,
      createLiveCamera: createCamera ?? () => camera,
      // Nothing to display in these tests: only the logic.
      decodeLiveFrame: (_) async => null,
      liveClock: () => now,
    );
    session.live.notices.listen(notices.add);
    return session;
  }

  tearDown(() {
    current?.dispose();
    current = null;
  });

  /// Lets the sharing loop run.
  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('camera owner', () {
    test('nothing is filmed before the user agrees', () async {
      final session = newSession();
      session.receive(const LiveRequestFrame(sid: 's1'));
      await settle();

      expect(session.live.share, LiveShare.asked);
      expect(camera.opened, isFalse);
      expect(sent, isEmpty);
    });

    test('agreeing turns the camera on, then frames leave', () async {
      final session = newSession();
      session.receive(const LiveRequestFrame(sid: 's1'));

      final running = session.live.acceptRequest();
      await settle();
      addTearDown(() async {
        session.live.stopSharing();
        await running;
      });

      expect(camera.opened, isTrue);
      expect(session.live.share, LiveShare.sharing);
      expect(sent.first, isA<LiveAcceptFrame>());
      final frame = sent.whereType<LiveVideoFrame>().first;
      expect(base64Decode(frame.data), camera.frame);
      expect(frame.n, 1);
    });

    test('refusing leaves the camera off and tells the peer', () async {
      final session = newSession();
      session.receive(const LiveRequestFrame(sid: 's1'));
      session.live.declineRequest();
      await settle();

      expect(camera.opened, isFalse);
      expect(session.live.share, LiveShare.idle);
      expect((sent.single as LiveEndFrame).reason, LiveEndReason.declined);
    });

    test('after a refusal, new requests are refused without asking', () async {
      final session = newSession();
      session.receive(const LiveRequestFrame(sid: 's1'));
      session.live.declineRequest();
      sent.clear();

      now = kLiveDeclineCooldownSeconds * 1000 - 1;
      session.receive(const LiveRequestFrame(sid: 's1'));
      expect(session.live.share, LiveShare.idle);
      expect((sent.single as LiveEndFrame).reason, LiveEndReason.declined);

      now = kLiveDeclineCooldownSeconds * 1000;
      session.receive(const LiveRequestFrame(sid: 's1'));
      expect(session.live.share, LiveShare.asked);
    });

    test('a withdrawn request removes the question', () {
      final session = newSession();
      session.receive(const LiveRequestFrame(sid: 's1'));
      session.receive(const LiveStopFrame(sid: 's1'));
      expect(session.live.share, LiveShare.idle);
      expect(sent, isEmpty);
    });

    test('the viewer closing the view turns the camera off', () async {
      final session = newSession();
      session.receive(const LiveRequestFrame(sid: 's1'));
      final running = session.live.acceptRequest();
      await settle();

      session.receive(const LiveStopFrame(sid: 's1'));
      await running;
      await settle();

      expect(camera.closed, isTrue);
      expect(session.live.share, LiveShare.idle);
    });

    test('stopping turns the camera off and tells the viewer', () async {
      final session = newSession();
      session.receive(const LiveRequestFrame(sid: 's1'));
      final running = session.live.acceptRequest();
      await settle();

      session.live.stopSharing();
      await running;
      await settle();

      expect(camera.closed, isTrue);
      expect(session.live.share, LiveShare.idle);
      expect((sent.last as LiveEndFrame).reason, LiveEndReason.stopped);
    });

    test('hiding the app turns the camera off', () async {
      final session = newSession();
      session.receive(const LiveRequestFrame(sid: 's1'));
      final running = session.live.acceptRequest();
      await settle();

      session.live.onAppHidden();
      await running;
      await settle();

      expect(camera.closed, isTrue);
      expect(session.live.share, LiveShare.idle);
    });

    test('the conversation ending turns the camera off', () async {
      final session = newSession();
      session.receive(const LiveRequestFrame(sid: 's1'));
      final running = session.live.acceptRequest();
      await settle();

      session.markPeerLeft();
      await running;
      await settle();

      expect(camera.closed, isTrue);
      expect(session.live.share, LiveShare.idle);
    });

    test('no camera, or a refused one: the viewer and the user know', () async {
      final session = newSession();
      camera.failure = const LiveCameraException('Aucune caméra détectée.');
      session.receive(const LiveRequestFrame(sid: 's1'));
      await session.live.acceptRequest();
      await settle();

      expect(session.live.share, LiveShare.idle);
      expect((sent.single as LiveEndFrame).reason, LiveEndReason.unavailable);
      expect(notices, ['Aucune caméra détectée.']);
    });

    test('a camera failing while shared stops the sharing', () async {
      final session = newSession();
      session.receive(const LiveRequestFrame(sid: 's1'));
      camera.frameFailure = const LiveCameraException('La caméra s’est arrêtée.');
      await session.live.acceptRequest();
      await settle();

      expect(session.live.share, LiveShare.idle);
      expect(camera.closed, isTrue);
      expect((sent.last as LiveEndFrame).reason, LiveEndReason.unavailable);
    });

    test('frames skip instead of queueing on a slow network', () async {
      final session = newSession();
      session.receive(const LiveRequestFrame(sid: 's1'));
      final running = session.live.acceptRequest();
      // No acknowledgement: time passes, but no more than the window leaves.
      for (var i = 0; i < 20; i++) {
        now += 10;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(sent.whereType<LiveVideoFrame>(), hasLength(kLiveWindowFrames));

      session.receive(const LiveAckFrame(sid: 's1', n: kLiveWindowFrames));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        sent.whereType<LiveVideoFrame>().length,
        greaterThan(kLiveWindowFrames),
      );
      session.live.stopSharing();
      await running;
    });

    test('full screen on the other side asks the camera for more', () async {
      final session = newSession();
      session.receive(const LiveRequestFrame(sid: 's1'));
      final running = session.live.acceptRequest();
      await settle();
      session.receive(const LiveSizeFrame(sid: 's1', side: kLiveFullSide));
      session.receive(const LiveAckFrame(sid: 's1', n: kLiveWindowFrames));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(camera.captureSides, [kLiveFullSide]);
      expect(camera.sides.last, kLiveFullStartSide);
      session.live.stopSharing();
      await running;
    });

    test('an absurd size is brought back within the limits', () async {
      final session = newSession();
      session.receive(const LiveRequestFrame(sid: 's1'));
      final running = session.live.acceptRequest();
      await settle();
      session.receive(const LiveSizeFrame(sid: 's1', side: 100000));
      await settle();
      expect(camera.captureSides, [kLiveFullSide]);
      session.live.stopSharing();
      await running;
    });

    test('a size is ignored while the camera is off', () {
      final session = newSession();
      session.receive(const LiveSizeFrame(sid: 's1', side: kLiveFullSide));
      expect(camera.captureSides, isEmpty);
      expect(camera.opened, isFalse);
    });

    test('a frame too large is not sent, and the quality drops', () async {
      final session = newSession();
      camera.frame = Uint8List(kMaxLiveFrameBytes + 1);
      session.receive(const LiveRequestFrame(sid: 's1'));
      final running = session.live.acceptRequest();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(sent.whereType<LiveVideoFrame>(), isEmpty);
      expect(camera.qualities.last, lessThan(kLiveQualityStart));
      session.live.stopSharing();
      await running;
    });
  });

  group('viewer', () {
    const frame = LiveVideoFrame(sid: 's1', n: 1, data: '/9j/2Q==');

    test('asking sends a request, and frames wait for the agreement', () async {
      final session = newSession();
      session.live.request();
      expect(sent.single, isA<LiveRequestFrame>());
      expect(session.live.watch, LiveWatch.requesting);

      session.receive(frame);
      await settle();
      expect(sent.whereType<LiveAckFrame>(), isEmpty);

      session.receive(const LiveAcceptFrame(sid: 's1'));
      expect(session.live.watch, LiveWatch.watching);
      session.receive(frame);
      await settle();
      expect(sent.whereType<LiveAckFrame>().single.n, 1);
    });

    test('an agreement nobody asked for is ignored', () {
      final session = newSession();
      session.receive(const LiveAcceptFrame(sid: 's1'));
      expect(session.live.watch, LiveWatch.idle);
    });

    test('frames nobody asked for are ignored', () async {
      final session = newSession();
      session.receive(frame);
      await settle();
      expect(sent, isEmpty);
    });

    test('an old frame is dropped', () async {
      final session = newSession();
      session.live.request();
      session.receive(const LiveAcceptFrame(sid: 's1'));
      session.receive(const LiveVideoFrame(sid: 's1', n: 5, data: '/9j/2Q=='));
      await settle();
      sent.clear();
      session.receive(frame);
      await settle();
      expect(sent, isEmpty);
    });

    test('only the latest frame is decoded when they come fast', () async {
      sent = [];
      final decoded = <int>[];
      final session = current = ChatSession(
        sid: 's1',
        peer: peer,
        send: sent.add,
        decodeLiveFrame: (jpeg) async {
          decoded.add(jpeg.first);
          return null;
        },
      );
      void show() {}
      session.live.image.addListener(show);
      session.live.request();
      session.receive(const LiveAcceptFrame(sid: 's1'));
      for (var n = 1; n <= 5; n++) {
        session.receive(
          LiveVideoFrame(sid: 's1', n: n, data: base64Encode([n])),
        );
      }
      await settle();
      session.live.image.removeListener(show);
      expect(decoded, [1, 5]);
      // The acknowledgement covers the skipped ones.
      expect(sent.whereType<LiveAckFrame>().last.n, 5);
    });

    test('nothing is decoded while the view is not on screen', () async {
      sent = [];
      var decoded = 0;
      final session = current = ChatSession(
        sid: 's1',
        peer: peer,
        send: sent.add,
        decodeLiveFrame: (_) async {
          decoded++;
          return null;
        },
      );
      session.live.request();
      session.receive(const LiveAcceptFrame(sid: 's1'));
      session.receive(frame);
      await settle();
      expect(decoded, 0);
      expect(sent.whereType<LiveAckFrame>(), hasLength(1));
    });

    test('a refusal ends the wait, with a message', () async {
      final session = newSession();
      session.live.request();
      session.receive(
        const LiveEndFrame(sid: 's1', reason: LiveEndReason.declined),
      );
      await settle();
      expect(session.live.watch, LiveWatch.idle);
      expect(notices.single, contains('refusée'));
    });

    testWidgets('no answer: the request is given up', (tester) async {
      final session = newSession();
      session.live.request();
      await tester.pump(const Duration(seconds: kLiveRequestTimeoutSeconds));
      expect(session.live.watch, LiveWatch.idle);
      expect(sent.last, isA<LiveStopFrame>());
    });

    test('closing the view tells the owner', () {
      final session = newSession();
      session.live.request();
      session.receive(const LiveAcceptFrame(sid: 's1'));
      sent.clear();
      session.live.stopWatching();
      expect(sent.single, isA<LiveStopFrame>());
      expect(session.live.watch, LiveWatch.idle);
    });

    test('live frames do not rebuild the conversation', () async {
      final session = newSession();
      session.live.request();
      session.receive(const LiveAcceptFrame(sid: 's1'));
      var notified = 0;
      session.addListener(() => notified++);
      session.receive(frame);
      await settle();
      expect(notified, 0);
    });
  });

  group('what changes tells apart', () {
    test('the peer typing does not touch the timeline', () {
      final session = newSession();
      var timeline = 0, typing = 0, all = 0;
      session.timeline.addListener(() => timeline++);
      session.typing.addListener(() => typing++);
      session.addListener(() => all++);

      session.receive(const DraftSnapshotFrame(sid: 's1', seq: 1, text: 'sal'));
      expect((timeline, typing, all), (0, 1, 1));

      session.receive(
        const MessageCommitFrame(
          sid: 's1',
          seq: 2,
          text: 'salut',
          mid: '0011223344556677',
        ),
      );
      expect((timeline, typing, all), (1, 2, 2));
    });
  });

  group('sent together', () {
    test('a batch shares a group, and is answered once', () async {
      final session = newSession();
      final disk = MemoryFileStorage();
      final sender = ChatSession(
        sid: 's1',
        peer: peer,
        send: (frame) {
          sent.add(frame);
          if (frame is RelayedFrame) session.receive(frame);
        },
        files: disk,
      );
      addTearDown(sender.dispose);
      sender.sendBatch(
        files: [
          FakeChosenFile('a.txt', Uint8List(3)),
          FakeChosenFile('b.txt', Uint8List(4)),
        ],
      );
      final offers = sent.whereType<FileOfferFrame>().toList();
      expect(offers, hasLength(2));
      expect(offers.first.group, isNotNull);
      expect(offers.first.group, offers.last.group);
      expect(session.pendingFiles, hasLength(2));
      expect(session.inGroup(offers.first.group!), hasLength(2));
    });

    test('a single file has no group', () {
      final session = newSession();
      session.sendBatch(files: [FakeChosenFile('a.txt', Uint8List(3))]);
      expect(sent.whereType<FileOfferFrame>().single.group, isNull);
    });

    test('only the first answers the reply in progress', () {
      final session = newSession();
      session.receive(
        const MessageCommitFrame(
          sid: 's1',
          seq: 1,
          text: 'envoie',
          mid: '0011223344556677',
        ),
      );
      session.sendBatch(
        files: [
          FakeChosenFile('a.txt', Uint8List(3)),
          FakeChosenFile('b.txt', Uint8List(4)),
        ],
        replyTo: session.messages.first,
      );
      final offers = sent.whereType<FileOfferFrame>().toList();
      expect(offers.first.reply, '0011223344556677');
      expect(offers.last.reply, isNull);
    });

    test('accepting the group takes every file, one upload at a time', () async {
      final receiverSent = <Frame>[];
      final disk = MemoryFileStorage();
      final receiver = current = ChatSession(
        sid: 's1',
        peer: peer,
        send: receiverSent.add,
        files: disk,
      );
      final uploads = <Frame>[];
      final sender = ChatSession(sid: 's1', peer: peer, send: uploads.add);
      addTearDown(sender.dispose);
      final a = FakeChosenFile('a.bin', Uint8List(kFileChunkBytes * 2));
      final b = FakeChosenFile('b.bin', Uint8List(10));
      sender.sendBatch(files: [a, b]);
      for (final offer in uploads.whereType<FileOfferFrame>()) {
        receiver.receive(offer);
      }
      final group = receiver.messages.first.group!;

      await receiver.acceptGroup(group);
      expect(disk.sinks, hasLength(2));
      expect(receiver.pendingFiles, isEmpty);
      final accepts = receiverSent.whereType<FileAcceptFrame>().toList();
      expect(accepts, hasLength(2));

      for (final accept in accepts) {
        sender.receive(accept);
      }
      await settle();
      // Only the first file's chunks are leaving.
      final chunks = uploads.whereType<FileChunkFrame>().toList();
      expect(chunks.map((c) => c.fid).toSet(), hasLength(1));
      expect(b.reads, isEmpty);

      // First one finished: the next one starts.
      sender.receive(FileAckFrame(sid: 's1', fid: chunks.first.fid, count: 2));
      await settle();
      expect(b.reads, isNotEmpty);
    });

    test('refusing the group refuses what waits', () {
      final session = newSession();
      session.receive(
        const FileOfferFrame(
          sid: 's1',
          fid: '0011223344556677',
          name: 'a',
          size: 1,
          group: 'aaaabbbbccccdddd',
        ),
      );
      session.receive(
        const FileOfferFrame(
          sid: 's1',
          fid: '1122334455667788',
          name: 'b',
          size: 1,
          group: 'aaaabbbbccccdddd',
        ),
      );
      session.cancelGroup('aaaabbbbccccdddd');
      expect(session.pendingFiles, isEmpty);
      expect(sent.whereType<FileCancelFrame>(), hasLength(2));
    });
  });
}
