import 'dart:convert';

import 'package:dismessage/config.dart';
import 'package:dismessage/features/chat/chat_screen.dart';
import 'package:dismessage/services/camera_capture.dart';
import 'package:dismessage/services/chat_session.dart';
import 'package:dismessage/services/connection_service.dart';
import 'package:dismessage/services/contacts_service.dart';
import 'package:dismessage/services/identity_service.dart';
import 'package:dismessage/services/image_codec.dart';
import 'package:dismessage/services/voice_recorder.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'fakes.dart';

const peer = '318343691';
const theirs = 'aaaabbbbccccdddd';

final jpeg = img.encodeJpg(img.Image(width: 40, height: 30));
final encoded = EncodedImage(bytes: jpeg, width: 40, height: 30, preview: jpeg);
final voiceBytes = Uint8List.fromList(List.generate(64, (i) => i));

void main() {
  late ChatSession session;
  late List<Frame> sent;
  late FakeVoiceRecorder recorder;
  late FakeAudioBackend audio;
  late List<ImageSource> picked;

  Future<void> pumpChat(
    WidgetTester tester, {
    bool camera = false,
    FakeVoiceRecorder? mic,
    FakeCameraCapture? webcam,
  }) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = MemoryStore();
    sent = [];
    picked = [];
    session = ChatSession(sid: 's1', peer: peer, send: sent.add);
    recorder =
        mic ??
        FakeVoiceRecorder(
          result: RecordedVoice(
            bytes: voiceBytes,
            mime: 'audio/mp4',
            duration: const Duration(seconds: 3),
          ),
        );
    final connection = ConnectionService(
      identity: IdentityService(store),
      serverUri: ServerSettings(
        store,
        fallback: Uri.parse('ws://x/ws'),
      ).serverUri,
    );
    addTearDown(connection.dispose);
    final contacts = ContactsService(store);
    await contacts.save(peer, 'Alice');
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          session: session,
          connection: connection,
          contacts: contacts,
          pickImage: (source) async {
            picked.add(source);
            return jpeg;
          },
          cameraAvailable: camera,
          createCamera: () => webcam,
          encodeImage: (_) async => encoded,
          createRecorder: () => recorder,
          createAudioBackend: () => audio = FakeAudioBackend(),
        ),
      ),
    );
  }

  void receiveText(String text, {String mid = theirs}) => session.receive(
    MessageCommitFrame(
      sid: 's1',
      seq: session.messages.length + 1,
      text: text,
      mid: mid,
    ),
  );

  /// Types in the input and lets the live draft flush.
  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('chat-input')), text);
    await tester.pump(const Duration(milliseconds: kDraftBatchMs * 2));
  }

  Future<void> longPress(WidgetTester tester, String id) async {
    await tester.longPress(find.byKey(ValueKey('bubble-$id')));
    await tester.pumpAndSettle();
  }

  group('line breaks', () {
    testWidgets('the input accepts several lines', (tester) async {
      await pumpChat(tester);
      await type(tester, 'Ligne 1\nLigne 2');
      await tester.tap(find.byKey(const Key('send')));
      await tester.pump();
      final commit = sent.whereType<MessageCommitFrame>().single;
      expect(commit.text, 'Ligne 1\nLigne 2');
      expect(find.text('Ligne 1\nLigne 2'), findsOneWidget);
    });

    testWidgets('Enter sends, Shift+Enter does not', (tester) async {
      await pumpChat(tester);
      await type(tester, 'Salut');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(sent.whereType<MessageCommitFrame>(), isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(sent.whereType<MessageCommitFrame>().single.text, 'Salut');
    });
  });

  group('replies', () {
    testWidgets('reply from the menu quotes the original', (tester) async {
      await pumpChat(tester);
      receiveText('On se voit quand ?');
      await tester.pump();

      await longPress(tester, theirs);
      await tester.tap(find.byKey(const Key('action-reply')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reply-bar')), findsOneWidget);
      expect(find.text('Réponse à Alice'), findsOneWidget);

      await type(tester, 'Demain');
      await tester.tap(find.byKey(const Key('send')));
      await tester.pump();

      final commit = sent.whereType<MessageCommitFrame>().single;
      expect(commit.reply, theirs);
      expect(find.byKey(const Key('reply-bar')), findsNothing);
      expect(find.byKey(ValueKey('quote-${commit.mid}')), findsOneWidget);
      expect(find.text('Alice'), findsWidgets);
    });

    testWidgets('under a wider quote, the text stays left-aligned', (
      tester,
    ) async {
      await pumpChat(tester);
      receiveText('Une question assez longue pour élargir la citation ?');
      await tester.pump();
      session.receive(
        const MessageCommitFrame(
          sid: 's1',
          seq: 2,
          text: 'Oui',
          mid: '1111222233334444',
          reply: theirs,
        ),
      );
      await tester.pump();
      final quote = tester.getTopLeft(
        find.byKey(const ValueKey('quote-1111222233334444')),
      );
      final text = tester.getTopLeft(find.text('Oui'));
      expect(text.dx - quote.dx, lessThan(20));
    });

    testWidgets('swiping a bubble to the right replies to it', (tester) async {
      await pumpChat(tester);
      receiveText('Swipe moi');
      await tester.pump();
      await tester.drag(
        find.byKey(const ValueKey('bubble-$theirs')),
        const Offset(120, 0),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reply-bar')), findsOneWidget);

      await tester.tap(find.byKey(const Key('reply-cancel')));
      await tester.pump();
      expect(find.byKey(const Key('reply-bar')), findsNothing);
    });

    testWidgets('a received reply shows the quote of my message', (
      tester,
    ) async {
      await pumpChat(tester);
      await type(tester, 'Ça va ?');
      await tester.tap(find.byKey(const Key('send')));
      await tester.pump();
      final mine = sent.whereType<MessageCommitFrame>().single.mid;

      session.receive(
        MessageCommitFrame(
          sid: 's1',
          seq: 1,
          text: 'Oui !',
          mid: theirs,
          reply: mine,
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('quote-$theirs')), findsOneWidget);
      expect(find.text('Vous'), findsOneWidget);
    });
  });

  group('reactions', () {
    testWidgets('react to the peer bubble, then remove it', (tester) async {
      await pumpChat(tester);
      receiveText('Bonne nouvelle');
      await tester.pump();

      await longPress(tester, theirs);
      await tester.tap(find.byKey(const ValueKey('react-👍')));
      await tester.pumpAndSettle();
      expect(sent.whereType<ReactionFrame>().single.emoji, '👍');
      expect(find.byKey(const ValueKey('reaction-$theirs')), findsOneWidget);

      await longPress(tester, theirs);
      await tester.tap(find.byKey(const Key('react-remove')));
      await tester.pumpAndSettle();
      expect(sent.whereType<ReactionFrame>().last.emoji, '');
      expect(find.byKey(const ValueKey('reaction-$theirs')), findsNothing);
    });

    testWidgets('any emoji from the full panel', (tester) async {
      await pumpChat(tester);
      receiveText('Choisis');
      await tester.pump();
      await longPress(tester, theirs);
      await tester.tap(find.byKey(const Key('react-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('emoji-😉')));
      await tester.pumpAndSettle();
      expect(sent.whereType<ReactionFrame>().single.emoji, '😉');
    });

    testWidgets('my own bubbles offer no reaction, only reply', (tester) async {
      await pumpChat(tester);
      await type(tester, 'Moi');
      await tester.tap(find.byKey(const Key('send')));
      await tester.pump();
      final mine = sent.whereType<MessageCommitFrame>().single.mid;

      await longPress(tester, mine);
      expect(find.byKey(const ValueKey('react-👍')), findsNothing);
      expect(find.byKey(const Key('action-reply')), findsOneWidget);
    });

    testWidgets("the peer's reaction shows on my bubble", (tester) async {
      await pumpChat(tester);
      await type(tester, 'Moi');
      await tester.tap(find.byKey(const Key('send')));
      await tester.pump();
      final mine = sent.whereType<MessageCommitFrame>().single.mid;

      session.receive(ReactionFrame(sid: 's1', ref: mine, emoji: '❤️'));
      await tester.pump();
      expect(find.byKey(ValueKey('reaction-$mine')), findsOneWidget);
      expect(find.text('❤️'), findsOneWidget);
    });
  });

  group('photo', () {
    testWidgets('one button offers the camera and the gallery', (tester) async {
      await pumpChat(tester, camera: true);
      await tester.tap(find.byKey(const Key('send-image')));
      await tester.pumpAndSettle();
      expect(find.text('Prendre une photo'), findsOneWidget);
      expect(find.text('Choisir dans la galerie'), findsOneWidget);

      await tester.tap(find.byKey(const Key('pick-camera')));
      await tester.pumpAndSettle();
      expect(picked, [ImageSource.camera]);
      expect(sent.whereType<ImageOfferFrame>(), hasLength(1));

      await tester.tap(find.byKey(const Key('send-image')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pick-gallery')));
      await tester.pumpAndSettle();
      expect(picked, [ImageSource.camera, ImageSource.gallery]);
    });

    testWidgets('on PC, "take a photo" opens the webcam, then sends', (
      tester,
    ) async {
      final webcam = FakeCameraCapture();
      await pumpChat(tester, camera: true, webcam: webcam);
      await tester.tap(find.byKey(const Key('send-image')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pick-camera')));
      await tester.pumpAndSettle();

      expect(webcam.opened, isTrue);
      expect(find.byKey(const Key('fake-preview')), findsOneWidget);
      await tester.tap(find.byKey(const Key('camera-shutter')));
      await tester.pumpAndSettle();

      expect(picked, isEmpty, reason: 'image_picker is not used');
      expect(sent.whereType<ImageOfferFrame>(), hasLength(1));
      expect(webcam.closed, isTrue, reason: 'the webcam is released');
    });

    testWidgets('closing the webcam sends nothing', (tester) async {
      final webcam = FakeCameraCapture();
      await pumpChat(tester, camera: true, webcam: webcam);
      await tester.tap(find.byKey(const Key('send-image')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pick-camera')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('camera-close')));
      await tester.pumpAndSettle();
      expect(sent.whereType<ImageOfferFrame>(), isEmpty);
      expect(webcam.closed, isTrue);
    });

    testWidgets('a missing or refused webcam says why', (tester) async {
      final webcam = FakeCameraCapture(
        failure: const CameraCaptureException('Aucune webcam détectée.'),
      );
      await pumpChat(tester, camera: true, webcam: webcam);
      await tester.tap(find.byKey(const Key('send-image')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pick-camera')));
      await tester.pumpAndSettle();
      expect(find.text('Aucune webcam détectée.'), findsOneWidget);
      // The shutter does nothing.
      await tester.tap(find.byKey(const Key('camera-shutter')));
      await tester.pumpAndSettle();
      expect(sent.whereType<ImageOfferFrame>(), isEmpty);
    });

    testWidgets('an unexpected failure shows its cause', (tester) async {
      await pumpChat(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(
            session: session,
            connection: ConnectionService(
              identity: IdentityService(MemoryStore()),
              serverUri: Uri.parse('ws://x/ws'),
            ),
            contacts: ContactsService(MemoryStore()),
            pickImage: (_) async => throw StateError('picker cassé'),
            cameraAvailable: false,
            createCamera: () => null,
            createAudioBackend: FakeAudioBackend.new,
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('send-image')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('picker cassé'), findsOneWidget);
      expect(sent.whereType<ImageOfferFrame>(), isEmpty);
    });

    testWidgets('without camera the gallery opens directly', (tester) async {
      await pumpChat(tester);
      await tester.tap(find.byKey(const Key('send-image')));
      await tester.pumpAndSettle();
      expect(find.text('Prendre une photo'), findsNothing);
      expect(picked, [ImageSource.gallery]);
    });
  });

  group('voice', () {
    testWidgets('the microphone replaces send while the input is empty', (
      tester,
    ) async {
      await pumpChat(tester);
      expect(find.byKey(const Key('record-voice')), findsOneWidget);
      await type(tester, 'a');
      await tester.pump();
      expect(find.byKey(const Key('record-voice')), findsNothing);
      expect(find.byKey(const Key('send')), findsOneWidget);
    });

    testWidgets('record then send a voice message', (tester) async {
      await pumpChat(tester);
      await tester.tap(find.byKey(const Key('record-voice')));
      await tester.pump();
      expect(recorder.recording, isTrue);
      expect(find.byKey(const Key('recording')), findsOneWidget);
      expect(find.text('Enregistrement…'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byKey(const Key('send')));
      await tester.pump();
      final frame = sent.whereType<VoiceFrame>().single;
      expect(base64Decode(frame.data), voiceBytes);
      expect(frame.durationMs, 3000);
      expect(find.byKey(const Key('recording')), findsNothing);
      expect(find.byKey(ValueKey('voice-play-${frame.mid}')), findsOneWidget);
    });

    testWidgets('cancelling a recording sends nothing', (tester) async {
      await pumpChat(tester);
      await tester.tap(find.byKey(const Key('record-voice')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('record-cancel')));
      await tester.pump();
      expect(recorder.cancelled, 1);
      expect(sent.whereType<VoiceFrame>(), isEmpty);
    });

    testWidgets('the recording stops and leaves at the maximum duration', (
      tester,
    ) async {
      await pumpChat(tester);
      recorder.maxDuration = const Duration(seconds: 2);
      await tester.tap(find.byKey(const Key('record-voice')));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2100)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(sent.whereType<VoiceFrame>(), hasLength(1));
    });

    testWidgets('a refused microphone explains why', (tester) async {
      await pumpChat(
        tester,
        mic: FakeVoiceRecorder(
          failure: const VoiceRecorderException('Autorisez le micro.'),
        ),
      );
      await tester.tap(find.byKey(const Key('record-voice')));
      await tester.pump();
      expect(find.text('Autorisez le micro.'), findsOneWidget);
      expect(find.byKey(const Key('recording')), findsNothing);
    });

    testWidgets('a received voice message plays on tap', (tester) async {
      await pumpChat(tester);
      session.receive(
        VoiceFrame(
          sid: 's1',
          mid: theirs,
          durationMs: 7000,
          mime: 'audio/mp4',
          data: base64Encode(voiceBytes),
        ),
      );
      await tester.pump();
      expect(find.text('0:07'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('voice-play-$theirs')));
      await tester.pump();
      expect(audio.played.single, voiceBytes);
      expect(find.byTooltip('Pause'), findsOneWidget);

      audio.complete();
      await tester.pump();
      expect(find.byTooltip('Écouter'), findsOneWidget);
    });
  });
}
