import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dismessage/services/chat_session.dart';
import 'package:dismessage/services/live_audio.dart';
import 'package:dismessage/services/live_camera.dart';
import 'package:dismessage/services/live_link.dart';
import 'package:dismessage/services/live_video.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const peer = '318343691';

void main() {
  late List<Frame> sent;
  late FakeLiveCamera camera;
  late FakeLiveMicrophone microphone;
  late FakeLiveSpeaker speaker;
  late int now;
  late List<String> notices;
  ChatSession? current;

  ChatSession newSession({
    LiveCamera? Function()? createCamera,
    LiveMicrophone? Function()? createMicrophone,
    LiveSpeaker? Function()? createSpeaker,
    LiveVideoCodecs? video,
  }) {
    sent = [];
    now = 0;
    notices = [];
    camera = FakeLiveCamera();
    microphone = FakeLiveMicrophone();
    speaker = FakeLiveSpeaker();
    final session = current = ChatSession(
      sid: 's1',
      peer: peer,
      send: sent.add,
      createLiveCamera: createCamera ?? () => camera,
      createLiveMicrophone: createMicrophone ?? () => microphone,
      createLiveSpeaker: createSpeaker ?? () => speaker,
      // Nothing to display in these tests: only the logic.
      decodeLiveFrame: (_) async => null,
      liveVideo: video ?? const NoLiveVideo(),
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
      camera.frameFailure = const LiveCameraException(
        'La caméra s’est arrêtée.',
      );
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

  group('video', () {
    /// A video frame from the owner.
    LiveVideoFrame videoFrame(int n, {bool key = false, int rotation = 0}) =>
        LiveVideoFrame(
          sid: 's1',
          n: n,
          data: base64Encode([n]),
          key: key,
          rotation: rotation,
        );

    /// The view on screen, watching an owner who chose H.264.
    (ChatSession, FakeLiveVideo) watching() {
      final video = FakeLiveVideo();
      final session = newSession(video: video);
      session.live.image.addListener(() {});
      session.live.request();
      session.receive(const LiveAcceptFrame(sid: 's1', codec: kLiveCodecH264));
      return (session, video);
    }

    group('camera owner', () {
      Future<(ChatSession, Future<void>)> sharing({
        List<String> offered = const [kLiveCodecH264],
        Set<String> encodes = const {kLiveCodecH264},
        int rotation = 0,
      }) async {
        final session = newSession();
        camera
          ..codecs = encodes
          ..rotation = rotation;
        session.receive(LiveRequestFrame(sid: 's1', codecs: offered));
        final running = session.live.acceptRequest();
        await settle();
        addTearDown(() async {
          session.live.stopSharing();
          await running;
        });
        return (session, running);
      }

      test('both sides can: video, from a key frame, larger', () async {
        final (session, _) = await sharing();
        expect((sent.first as LiveAcceptFrame).codec, kLiveCodecH264);
        expect(session.live.sharedCodec, kLiveCodecH264);
        final first = sent.whereType<LiveVideoFrame>().first;
        expect(first.key, isTrue);
        expect(base64Decode(first.data), camera.frame);
        expect(camera.requests.first.codec, kLiveCodecH264);
        expect(camera.requests.first.key, isTrue);
        expect(camera.requests.first.kbps, kLiveStartKbps);
        expect(camera.requests.first.side, kLiveVideoSmallSide);
        expect(camera.captureSides, contains(kLiveVideoSmallSide));
        // The following ones need it: no key frame unless asked for.
        expect(sent.whereType<LiveVideoFrame>().skip(1).first.key, isFalse);
      });

      test('an older viewer gets JPEG, whatever the camera can do', () async {
        final (session, _) = await sharing(offered: const []);
        expect((sent.first as LiveAcceptFrame).codec, isNull);
        expect(session.live.sharedCodec, isNull);
        expect(camera.requests.first.codec, isNull);
        expect(sent.whereType<LiveVideoFrame>().first.key, isFalse);
      });

      test('a camera without encoder sends JPEG', () async {
        await sharing(encodes: const {});
        expect((sent.first as LiveAcceptFrame).codec, isNull);
        expect(camera.requests.first.codec, isNull);
      });

      test('the viewer asks for a key frame: the next one is', () async {
        final (session, _) = await sharing();
        session.receive(const LiveKeyFrame(sid: 's1'));
        final asked = camera.requests.length;
        // Acknowledgements let the next frames leave.
        session.receive(
          LiveAckFrame(sid: 's1', n: sent.whereType<LiveVideoFrame>().last.n),
        );
        await settle();
        expect(camera.requests.skip(asked).first.key, isTrue);
        // Then deltas again.
        expect(camera.requests.last.key, isFalse);
      });

      test('the turn of a phone camera goes with each frame', () async {
        await sharing(rotation: 270);
        expect(sent.whereType<LiveVideoFrame>().first.rotation, 270);
      });

      test('a frame too large is skipped and a key frame follows', () async {
        final (session, _) = await sharing();
        final kbps = session.live.flow!.kbps;
        camera.frame = Uint8List(kMaxLiveFrameBytes + 1);
        final before = sent.whereType<LiveVideoFrame>().length;
        session.receive(
          LiveAckFrame(sid: 's1', n: sent.whereType<LiveVideoFrame>().last.n),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(sent.whereType<LiveVideoFrame>(), hasLength(before));
        expect(session.live.flow!.kbps, lessThan(kbps));
        expect(camera.requests.last.key, isTrue);
      });

      test(
        'my own thumbnail comes from a small preview, now and then',
        () async {
          final session = newSession();
          camera.codecs = {kLiveCodecH264};
          session.live.ownImage.addListener(() {});
          session.receive(
            const LiveRequestFrame(sid: 's1', codecs: [kLiveCodecH264]),
          );
          final running = session.live.acceptRequest();
          await settle();
          session.live.stopSharing();
          await running;
          final previews = camera.requests.where((r) => r.preview).toList();
          expect(previews, isNotEmpty);
          expect(
            camera.requests.where((r) => r.preview).length,
            lessThan(camera.requests.length),
          );
        },
      );

      test('no preview when nobody looks at the thumbnail', () async {
        await sharing();
        expect(camera.requests.where((r) => r.preview), isEmpty);
      });

      test('full screen starts larger, with more bitrate', () async {
        final (session, _) = await sharing();
        session.receive(const LiveSizeFrame(sid: 's1', side: kLiveFullSide));
        session.receive(
          LiveAckFrame(sid: 's1', n: sent.whereType<LiveVideoFrame>().last.n),
        );
        await settle();
        expect(camera.requests.last.side, kLiveVideoFullStartSide);
        expect(camera.requests.last.kbps, kLiveFullStartKbps);
        expect(camera.captureSides.last, kLiveFullSide);
      });
    });

    group('viewer', () {
      test('the request offers what this device decodes', () {
        final session = newSession(video: FakeLiveVideo());
        session.live.request();
        expect((sent.single as LiveRequestFrame).codecs, [kLiveCodecH264]);
      });

      test('a device without decoder offers nothing: JPEG', () {
        final session = newSession(video: FakeLiveVideo(codecs: {}));
        session.live.request();
        expect((sent.single as LiveRequestFrame).codecs, isEmpty);
      });

      test('frames are decoded in order, all of them, then shown', () async {
        final (session, video) = watching();
        session.receive(videoFrame(1, key: true, rotation: 90));
        for (var n = 2; n <= 5; n++) {
          session.receive(videoFrame(n, rotation: 90));
        }
        await settle();
        final decoder = video.created.single;
        expect(decoder.decoded.map((d) => d.data.single), [1, 2, 3, 4, 5]);
        expect(decoder.decoded.first.key, isTrue);
        expect(session.live.codec, kLiveCodecH264);
        final picture = session.live.image.value!;
        expect(picture.texture, decoder.texture);
        expect(picture.rotation, 90);
        expect(picture.aspectRatio, 480 / 640);
        expect(sent.whereType<LiveAckFrame>().last.n, 5);
      });

      test('a delta without its key frame waits, and one is asked', () async {
        final (session, video) = watching();
        session.receive(videoFrame(1));
        session.receive(videoFrame(2));
        await settle();
        expect(video.created, isEmpty);
        // Asked once, not for every frame.
        expect(sent.whereType<LiveKeyFrame>(), hasLength(1));
        // Acknowledged all the same: the owner goes on.
        expect(sent.whereType<LiveAckFrame>().last.n, 2);
        now += kLiveKeyRequestMs;
        session.receive(videoFrame(3));
        expect(sent.whereType<LiveKeyFrame>(), hasLength(2));
        session.receive(videoFrame(4, key: true));
        await settle();
        expect(video.created.single.decoded.single.data.single, 4);
      });

      test('nothing is decoded off screen; back on it, a key frame', () async {
        final video = FakeLiveVideo();
        final session = newSession(video: video);
        session.live.request();
        session.receive(
          const LiveAcceptFrame(sid: 's1', codec: kLiveCodecH264),
        );
        session.receive(videoFrame(1, key: true));
        session.receive(videoFrame(2));
        await settle();
        expect(video.created, isEmpty);
        expect(sent.whereType<LiveAckFrame>().last.n, 2);

        void show() {}
        session.live.image.addListener(show);
        session.receive(videoFrame(3));
        await settle();
        expect(video.created, isEmpty);
        expect(sent.whereType<LiveKeyFrame>(), hasLength(1));
        session.receive(videoFrame(4, key: true));
        await settle();
        expect(video.created.single.decoded, hasLength(1));
        session.live.image.removeListener(show);
      });

      test('a broken frame: a new decoder, from a key frame', () async {
        final (session, video) = watching();
        session.receive(videoFrame(1, key: true));
        await settle();
        final first = video.created.single..failNext = true;
        session.receive(videoFrame(2));
        await settle();
        expect(first.closed, isTrue);
        expect(sent.whereType<LiveKeyFrame>(), hasLength(1));
        session.receive(videoFrame(3));
        await settle();
        expect(video.created, hasLength(1));
        session.receive(videoFrame(4, key: true));
        await settle();
        expect(video.created, hasLength(2));
        expect(video.created.last.decoded.single.key, isTrue);
      });

      test('too far behind: dropped, and a key frame asked', () async {
        final (session, video) = watching();
        session.receive(videoFrame(1, key: true));
        await settle();
        final decoder = video.created.single..gate = Completer<void>();
        for (var n = 2; n <= kLiveMaxQueuedFrames + 3; n++) {
          session.receive(videoFrame(n));
        }
        expect(sent.whereType<LiveKeyFrame>(), hasLength(1));
        decoder.gate!.complete();
        await settle();
        // Only what was being decoded when it fell behind.
        expect(decoder.decoded.length, lessThan(4));
      });

      test('a codec that was not offered cannot be shown', () async {
        final session = newSession(video: FakeLiveVideo(codecs: {}));
        session.live.request();
        session.receive(
          const LiveAcceptFrame(sid: 's1', codec: kLiveCodecH264),
        );
        await settle();
        expect(session.live.watch, LiveWatch.idle);
        expect(sent.last, isA<LiveStopFrame>());
        expect(notices.single, contains('mettez Dismessage à jour'));
      });

      test('closing the view closes the decoder', () async {
        final (session, video) = watching();
        session.receive(videoFrame(1, key: true));
        await settle();
        session.live.stopWatching();
        expect(video.created.single.closed, isTrue);
        expect(session.live.image.value, isNull);
        expect(session.live.codec, isNull);
      });

      test('the owner ignores key requests while sending JPEG', () async {
        final session = newSession();
        session.receive(const LiveRequestFrame(sid: 's1'));
        final running = session.live.acceptRequest();
        await settle();
        session.receive(const LiveKeyFrame(sid: 's1'));
        session.receive(
          LiveAckFrame(sid: 's1', n: sent.whereType<LiveVideoFrame>().last.n),
        );
        await settle();
        expect(camera.requests.every((r) => !r.key && r.codec == null), isTrue);
        session.live.stopSharing();
        await running;
      });
    });
  });

  group('sound', () {
    const askWithSound = LiveRequestFrame(sid: 's1', audio: [kLiveAudioAdpcm]);

    test('the microphone turns on with the camera, then sound leaves', () async {
      final session = newSession();
      session.receive(askWithSound);
      expect(session.live.asksMicrophone, isTrue);
      expect(microphone.opened, isFalse);

      final running = session.live.acceptRequest();
      await settle();
      addTearDown(() async {
        session.live.stopSharing();
        await running;
      });
      expect(microphone.opened, isTrue);
      expect(sent.whereType<LiveAcceptFrame>().single.audio, kLiveAudioAdpcm);
      expect(session.live.sharedAudio, kLiveAudioAdpcm);

      microphone.speak(kLiveAudioPacketMs * 3);
      final packets = sent.whereType<LiveAudioFrame>().toList();
      expect(packets.map((p) => p.n), [1, 2, 3]);
      final samples = ImaAdpcm.decode(base64Decode(packets.first.data))!;
      expect(samples, hasLength(kLiveAudioPacketSamples));
    });

    test('nothing is heard before the user agrees', () async {
      final session = newSession();
      session.receive(askWithSound);
      await settle();
      expect(microphone.opened, isFalse);
      session.live.declineRequest();
      expect(microphone.opened, isFalse);
    });

    test('"Sans le micro" shares the camera alone', () async {
      final session = newSession();
      session.receive(askWithSound);
      final running = session.live.acceptRequest(microphone: false);
      await settle();
      addTearDown(() async {
        session.live.stopSharing();
        await running;
      });
      expect(microphone.opened, isFalse);
      expect(sent.whereType<LiveAcceptFrame>().single.audio, isNull);
      expect(session.live.sharedAudio, isNull);
    });

    test('an older viewer, who cannot play sound, gets none', () async {
      final session = newSession();
      session.receive(const LiveRequestFrame(sid: 's1'));
      expect(session.live.asksMicrophone, isFalse);
      final running = session.live.acceptRequest();
      await settle();
      addTearDown(() async {
        session.live.stopSharing();
        await running;
      });
      expect(microphone.opened, isFalse);
      expect(sent.whereType<LiveAcceptFrame>().single.audio, isNull);
    });

    test('a refused microphone: the camera alone, and the user knows', () async {
      final session = newSession(
        createMicrophone: () => FakeLiveMicrophone(
          failure: const LiveAudioException('Accès au micro refusé.'),
        ),
      );
      session.receive(askWithSound);
      final running = session.live.acceptRequest();
      await settle();
      addTearDown(() async {
        session.live.stopSharing();
        await running;
      });
      expect(session.live.share, LiveShare.sharing);
      expect(sent.whereType<LiveAcceptFrame>().single.audio, isNull);
      expect(notices, ['Accès au micro refusé.']);
    });

    test('muting stops the sound and tells the viewer', () async {
      final session = newSession();
      session.receive(askWithSound);
      final running = session.live.acceptRequest();
      await settle();
      addTearDown(() async {
        session.live.stopSharing();
        await running;
      });

      session.live.setMicMuted(true);
      expect(session.live.micMuted, isTrue);
      expect(sent.whereType<LiveMuteFrame>().single.muted, isTrue);
      microphone.speak(kLiveAudioPacketMs * 3);
      expect(sent.whereType<LiveAudioFrame>(), isEmpty);

      session.live.setMicMuted(false);
      expect(sent.whereType<LiveMuteFrame>().last.muted, isFalse);
      microphone.speak(kLiveAudioPacketMs);
      expect(sent.whereType<LiveAudioFrame>().single.n, 1);
    });

    test('the microphone goes off with the camera', () async {
      for (final stop in <void Function(ChatSession)>[
        (s) => s.live.stopSharing(),
        (s) => s.receive(const LiveStopFrame(sid: 's1')),
        (s) => s.live.onAppHidden(),
        (s) => s.live.onPeerLeft(),
      ]) {
        final session = newSession();
        session.receive(askWithSound);
        final running = session.live.acceptRequest();
        await settle();
        expect(microphone.opened, isTrue);
        stop(session);
        await running;
        await settle();
        expect(microphone.closed, isTrue);
        expect(session.live.sharedAudio, isNull);
        sent.clear();
        microphone.speak(kLiveAudioPacketMs * 2);
        expect(sent.whereType<LiveAudioFrame>(), isEmpty);
        session.dispose();
        current = null;
      }
    });

    test('stopped while the microphone turns on: it goes off', () async {
      final slow = Completer<void>();
      final mic = _SlowMicrophone(slow.future);
      final session = newSession(createMicrophone: () => mic);
      session.receive(askWithSound);
      final running = session.live.acceptRequest();
      await settle();
      session.live.stopSharing();
      slow.complete();
      await running;
      await settle();
      expect(mic.closed, isTrue);
      expect(sent.whereType<LiveAcceptFrame>(), isEmpty);
    });

    group('viewer', () {
      String packet(int ms) => base64Encode(
        ImaAdpcmEncoder().encode(Int16List(kLiveAudioSampleRate * ms ~/ 1000)),
      );

      Future<ChatSession> watching({String? audio = kLiveAudioAdpcm}) async {
        final session = newSession();
        session.live.request();
        session.receive(LiveAcceptFrame(sid: 's1', audio: audio));
        await settle();
        return session;
      }

      test('the request says sound can be played', () {
        final session = newSession();
        session.live.request();
        expect(sent.whereType<LiveRequestFrame>().single.audio, [
          kLiveAudioAdpcm,
        ]);
      });

      test('a device that cannot play asks for no sound', () {
        final session = newSession(createSpeaker: () => null);
        session.live.request();
        expect(sent.whereType<LiveRequestFrame>().single.audio, isEmpty);
      });

      test('the sound plays after a short buffer', () async {
        final session = await watching();
        expect(speaker.opened, isTrue);
        expect(session.live.sound.available, isTrue);
        const count = kLiveAudioStartMs ~/ kLiveAudioPacketMs;
        for (var n = 1; n <= count; n++) {
          if (n < count) {
            session.receive(
              LiveAudioFrame(sid: 's1', n: n, data: packet(kLiveAudioPacketMs)),
            );
            expect(speaker.played, isEmpty);
          } else {
            session.receive(
              LiveAudioFrame(sid: 's1', n: n, data: packet(kLiveAudioPacketMs)),
            );
          }
          now += kLiveAudioPacketMs;
        }
        expect(speaker.played, hasLength(count));
        // An old packet is dropped.
        session.receive(
          LiveAudioFrame(sid: 's1', n: 1, data: packet(kLiveAudioPacketMs)),
        );
        expect(speaker.played, hasLength(count));
      });

      test('no sound agreed: packets are ignored', () async {
        final session = await watching(audio: null);
        expect(session.live.sound.available, isFalse);
        expect(speaker.opened, isFalse);
        for (var n = 1; n <= 5; n++) {
          session.receive(
            LiveAudioFrame(sid: 's1', n: n, data: packet(kLiveAudioPacketMs)),
          );
        }
        expect(speaker.played, isEmpty);
      });

      test('sound nobody asked for is ignored', () async {
        final session = newSession();
        for (var n = 1; n <= 5; n++) {
          session.receive(
            LiveAudioFrame(sid: 's1', n: n, data: packet(kLiveAudioPacketMs)),
          );
        }
        expect(speaker.opened, isFalse);
        expect(speaker.played, isEmpty);
        expect(session.live.sound.available, isFalse);
      });

      test('muting on my side plays nothing', () async {
        final session = await watching();
        session.live.sound.toggle();
        for (var n = 1; n <= 5; n++) {
          session.receive(
            LiveAudioFrame(sid: 's1', n: n, data: packet(kLiveAudioPacketMs)),
          );
          now += kLiveAudioPacketMs;
        }
        expect(speaker.played, isEmpty);
      });

      test('the peer muting is shown, and what was gathered plays', () async {
        final session = await watching();
        session.receive(
          LiveAudioFrame(sid: 's1', n: 1, data: packet(kLiveAudioPacketMs)),
        );
        expect(speaker.played, isEmpty);
        session.receive(const LiveMuteFrame(sid: 's1', muted: true));
        expect(session.live.sound.peerMuted, isTrue);
        expect(speaker.played, hasLength(1));
        session.receive(const LiveMuteFrame(sid: 's1', muted: false));
        expect(session.live.sound.peerMuted, isFalse);
      });

      test('a broken packet is ignored', () async {
        final session = await watching();
        session.receive(const LiveAudioFrame(sid: 's1', n: 1, data: 'AAAA'));
        session.receive(const LiveAudioFrame(sid: 's1', n: 2, data: '%%%'));
        expect(speaker.played, isEmpty);
      });

      test('the speaker closes with the view, and the sound is reset', () async {
        final session = await watching();
        session.live.sound.toggle();
        session.live.stopWatching();
        expect(speaker.closed, isTrue);
        expect(session.live.sound.available, isFalse);
        expect(session.live.sound.on, isTrue);
      });

      test('a speaker that cannot open: told, no sound', () async {
        final session = newSession(
          createSpeaker: () => FakeLiveSpeaker(
            failure: const LiveAudioException('Son indisponible.'),
          ),
        );
        session.live.request();
        session.receive(
          const LiveAcceptFrame(sid: 's1', audio: kLiveAudioAdpcm),
        );
        await settle();
        expect(session.live.sound.available, isFalse);
        expect(notices, ['Impossible de jouer le son sur cet appareil.']);
      });
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

    test(
      'accepting the group takes every file, one upload at a time',
      () async {
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
        sender.receive(
          FileAckFrame(sid: 's1', fid: chunks.first.fid, count: 2),
        );
        await settle();
        expect(b.reads, isNotEmpty);
      },
    );

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

/// A microphone that takes its time to turn on.
class _SlowMicrophone implements LiveMicrophone {
  _SlowMicrophone(this._ready);

  final Future<void> _ready;
  bool closed = false;

  @override
  Future<void> open(void Function(Uint8List pcm) onPcm) => _ready;

  @override
  Future<void> close() async => closed = true;
}
