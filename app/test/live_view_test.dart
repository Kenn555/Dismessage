import 'package:dismessage/config.dart';
import 'package:dismessage/features/chat/chat_screen.dart';
import 'package:dismessage/features/chat/overlay_panel.dart';
import 'package:dismessage/services/live_video.dart';
import 'package:dismessage/services/clipboard_images.dart';
import 'package:dismessage/services/attachments.dart';
import 'package:dismessage/services/chat_session.dart';
import 'package:dismessage/services/connection_service.dart';
import 'package:dismessage/services/contacts_service.dart';
import 'package:dismessage/services/identity_service.dart';
import 'package:dismessage/services/image_codec.dart';
import 'package:dismessage/services/live_fullscreen.dart';
import 'package:dismessage/services/live_link.dart';
import 'package:dismessage/widgets/live_view.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const peer = '318343691';

void main() {
  late ChatSession session;
  late List<Frame> sent;
  late FakeLiveCamera camera;
  late LiveFullscreen fullscreen;
  late List<bool> system;

  Future<void> pumpChat(
    WidgetTester tester, {
    Size size = const Size(900, 1000),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = MemoryStore();
    final contacts = ContactsService(store);
    sent = [];
    camera = FakeLiveCamera();
    system = [];
    session = ChatSession(
      sid: 's1',
      peer: peer,
      send: sent.add,
      createLiveCamera: () => camera,
      decodeLiveFrame: (_) async => null,
      liveVideo: const NoLiveVideo(),
    );
    final connection = ConnectionService(
      identity: IdentityService(store),
      serverUri: ServerSettings(
        store,
        fallback: Uri.parse('ws://x/ws'),
      ).serverUri,
    );
    fullscreen = LiveFullscreen(
      connection: connection,
      setSystem: (on) async => system.add(on),
    );
    addTearDown(fullscreen.dispose);
    addTearDown(connection.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => LiveFullscreenHost(
          fullscreen: fullscreen,
          panel: (s) => OverlayPanel(
            key: ValueKey('fullscreen-${s.sid}'),
            session: s,
            contacts: contacts,
            inFullscreen: true,
            onExit: fullscreen.exit,
            onFullscreen: fullscreen.exit,
            clipboardImages: const NoClipboardImages(),
          ),
          child: child!,
        ),
        home: ChatScreen(
          session: session,
          connection: connection,
          contacts: contacts,
          fullscreen: fullscreen,
          cameraAvailable: false,
          createCamera: () => null,
          createAudioBackend: FakeAudioBackend.new,
        ),
      ),
    );
  }

  /// Stops the camera loop before the test ends.
  Future<void> finish(WidgetTester tester) async {
    session.live.stopSharing();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> watch(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('live-toggle')));
    await tester.pump();
    session.receive(const LiveAcceptFrame(sid: 's1'));
    await tester.pump();
  }

  testWidgets('the header button asks, and shows that it waits', (
    tester,
  ) async {
    await pumpChat(tester);
    await tester.tap(find.byKey(const Key('live-toggle')));
    await tester.pump();

    expect(sent.single, isA<LiveRequestFrame>());
    expect(find.byKey(const Key('live-waiting')), findsOneWidget);

    await tester.tap(find.byKey(const Key('live-toggle')));
    await tester.pump();
    expect(sent.last, isA<LiveStopFrame>());
    expect(find.byKey(const Key('live-waiting')), findsNothing);
  });

  testWidgets('a video texture is shown upright, in its proportions', (
    tester,
  ) async {
    // A phone filming upright: 640 × 480 from its sensor, a quarter turn.
    final picture = ValueNotifier<LivePicture?>(
      const LivePicture.texture(7, width: 640, height: 480, rotation: 90),
    );
    addTearDown(picture.dispose);
    expect(liveAspectRatio(picture.value), 480 / 640);
    expect(liveAspectRatio(null), 4 / 3);
    await tester.pumpWidget(
      Center(
        child: SizedBox(
          width: 300,
          height: 400,
          child: LiveSurface(image: picture, fit: BoxFit.contain),
        ),
      ),
    );
    expect(tester.widget<Texture>(find.byType(Texture)).textureId, 7);
    expect(tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns, 1);
    // Fills the box, upright: 300 × 400.
    final shown = tester.getRect(find.byType(RotatedBox));
    expect(shown.width, closeTo(300, 0.5));
    expect(shown.height, closeTo(400, 0.5));

    // The same texture at another size: nothing else changes.
    picture.value = const LivePicture.texture(7, width: 1280, height: 720);
    await tester.pump();
    expect(tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns, 0);
    expect(tester.getRect(find.byType(RotatedBox)).width, closeTo(300, 0.5));
  });

  testWidgets('the view is above the input, half as wide as the field', (
    tester,
  ) async {
    await pumpChat(tester);
    await watch(tester);

    final view = tester.getRect(find.byKey(const Key('live-view')));
    final input = tester.getRect(find.byKey(const Key('chat-input')));
    expect(view.bottom, lessThanOrEqualTo(input.top));

    // The field: the screen less the margins and the send button.
    const field = 900.0 - 12 - 12 - 8 - 52;
    expect(view.width, closeTo(field / 2, 0.5));
    expect(view.left, 12);
  });

  testWidgets('a tap on the view puts it in full screen, Escape leaves', (
    tester,
  ) async {
    await pumpChat(tester);
    await watch(tester);

    await tester.tap(find.byKey(const Key('live-view-surface')));
    await tester.pump();
    expect(find.byKey(const Key('live-fullscreen')), findsOneWidget);
    expect(system, [true]);
    // The best the camera and the network can give.
    expect((sent.last as LiveSizeFrame).side, kLiveFullSide);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const Key('live-fullscreen')), findsNothing);
    expect(system, [true, false]);
    expect((sent.last as LiveSizeFrame).side, kLiveMaxSide);
  });

  testWidgets('full screen shows the panel at the bottom, ready to type', (
    tester,
  ) async {
    await pumpChat(tester);
    await watch(tester);
    await tester.tap(find.byKey(const Key('live-view-surface')));
    await tester.pump();
    await tester.pump();

    final panel = find.byKey(const Key('fullscreen-panel'));
    expect(panel, findsOneWidget);
    final rect = tester.getRect(panel);
    expect(rect.bottom, greaterThan(1000 - 40));
    expect(rect.bottom, lessThanOrEqualTo(1000));
    // Its small view would repeat what fills the screen.
    expect(find.byKey(const Key('overlay-live')), findsNothing);
    final context = FocusManager.instance.primaryFocus?.context;
    expect(context?.findAncestorWidgetOfExactType<OverlayPanel>(), isNotNull);

    // What is typed there is the conversation's draft, kept on leaving.
    tester.testTextInput.enterText('salut');
    await tester.pump(const Duration(milliseconds: 50));
    expect(session.localDraft, 'salut');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(fullscreen.active, isFalse);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('chat-input')))
          .controller
          ?.text,
      'salut',
    );
  });

  testWidgets('the wide screen shows the panel a third as wide, centered', (
    tester,
  ) async {
    await pumpChat(tester, size: const Size(1500, 900));
    await watch(tester);
    await fullscreen.enter(session);
    await tester.pump();
    final rect = tester.getRect(find.byKey(const Key('fullscreen-panel')));
    expect(rect.width, closeTo(500, 1));
    expect(rect.center.dx, closeTo(750, 1));
  });

  testWidgets('the shortcuts enter and leave full screen', (tester) async {
    await pumpChat(tester);
    await watch(tester);
    await tester.tap(find.byKey(const Key('chat-input')));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    expect(fullscreen.active, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    expect(fullscreen.active, isFalse);

    await tester.tap(find.byKey(const Key('chat-input')));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(fullscreen.active, isTrue);
  });

  testWidgets('without a view, F11 does nothing', (tester) async {
    await pumpChat(tester);
    await tester.tap(find.byKey(const Key('chat-input')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    expect(fullscreen.active, isFalse);
  });

  testWidgets('full screen ends when the camera is cut', (tester) async {
    await pumpChat(tester);
    await watch(tester);
    await fullscreen.enter(session);
    await tester.pump();

    session.receive(
      const LiveEndFrame(sid: 's1', reason: LiveEndReason.stopped),
    );
    await tester.pump();

    expect(fullscreen.active, isFalse);
    expect(find.byKey(const Key('live-view')), findsNothing);
    expect(find.text('La caméra a été coupée.'), findsOneWidget);
  });

  testWidgets('closing the view tells the peer', (tester) async {
    await pumpChat(tester);
    await watch(tester);
    await tester.tap(find.byKey(const Key('live-close')));
    await tester.pump();
    expect(sent.last, isA<LiveStopFrame>());
    expect(session.live.watch, LiveWatch.idle);
  });

  testWidgets('a request shows a question; the camera waits for the answer', (
    tester,
  ) async {
    await pumpChat(tester);
    session.receive(const LiveRequestFrame(sid: 's1'));
    await tester.pump();

    expect(find.byKey(const Key('live-request-banner')), findsOneWidget);
    expect(camera.opened, isFalse);

    await tester.tap(find.byKey(const Key('live-allow')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(camera.opened, isTrue);
    expect(find.byKey(const Key('live-request-banner')), findsNothing);
    expect(find.byKey(const Key('live-sharing-bar')), findsOneWidget);

    await tester.tap(find.byKey(const Key('live-stop-sharing')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(camera.closed, isTrue);
    expect(find.byKey(const Key('live-sharing-bar')), findsNothing);
    await finish(tester);
  });

  testWidgets('Enter in the input never answers the camera question', (
    tester,
  ) async {
    await pumpChat(tester);
    await tester.tap(find.byKey(const Key('chat-input')));
    await tester.pump();
    session.receive(const LiveRequestFrame(sid: 's1'));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(session.live.share, LiveShare.asked);
    expect(camera.opened, isFalse);
  });

  testWidgets('refusing keeps the camera off', (tester) async {
    await pumpChat(tester);
    session.receive(const LiveRequestFrame(sid: 's1'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('live-deny')));
    await tester.pump();

    expect(camera.opened, isFalse);
    expect(sent.single, isA<LiveEndFrame>());
    expect(find.byKey(const Key('live-request-banner')), findsNothing);
  });

  group('attachments', () {
    final picture = Uint8List.fromList([1, 2, 3]);
    EncodedImage encoded(Uint8List bytes) => EncodedImage(
      bytes: bytes,
      width: 4,
      height: 3,
      preview: Uint8List.fromList([9]),
    );

    ChatSession plain() {
      sent = [];
      return ChatSession(sid: 's1', peer: peer, send: sent.add);
    }

    test('a file that is a picture shows as an image', () async {
      final s = plain();
      addTearDown(s.dispose);
      final file = FakeChosenFile('vacances.JPG', picture);
      await sendAttachments(
        s,
        Attachments(files: [file]),
        encode: (b) async => encoded(b),
      );
      expect(sent.single, isA<ImageOfferFrame>());
      expect(file.closed, isTrue);
    });

    test('a broken picture still goes, as a file', () async {
      final s = plain();
      addTearDown(s.dispose);
      await sendAttachments(
        s,
        Attachments(files: [FakeChosenFile('faux.png', picture)]),
        encode: (_) async =>
            throw const ImageCodecException('Image illisible.'),
      );
      expect(sent.single, isA<FileOfferFrame>());
    });

    test('pictures and other files leave together, in one group', () async {
      final s = plain();
      addTearDown(s.dispose);
      await sendAttachments(
        s,
        Attachments(
          images: [picture],
          files: [
            FakeChosenFile('a.pdf', picture),
            FakeChosenFile('b.png', picture),
          ],
        ),
        encode: (b) async => encoded(b),
      );
      final images = sent.whereType<ImageOfferFrame>().toList();
      final files = sent.whereType<FileOfferFrame>().toList();
      expect((images.length, files.length), (2, 1));
      expect(images.first.group, isNotNull);
      expect(files.single.group, images.first.group);
    });

    test('too many files: the first ones leave, with a message', () async {
      final s = plain();
      addTearDown(s.dispose);
      final notice = await sendAttachments(
        s,
        Attachments(
          files: [
            for (var i = 0; i < kMaxFilesPerSend + 2; i++)
              FakeChosenFile('$i.txt', picture),
          ],
        ),
        encode: (b) async => encoded(b),
      );
      expect(sent.whereType<FileOfferFrame>(), hasLength(kMaxFilesPerSend));
      expect(notice, contains('$kMaxFilesPerSend'));
    });

    test('labels', () {
      expect(describeAttachments(0, 3), '3 fichiers');
      expect(describeAttachments(1, 2), '1 image et 2 fichiers');
      expect(describeAttachments(2, 0), '2 images');
    });
  });

  group('files sent together, in the conversation', () {
    Future<void> offerTwo() async {
      session.receive(
        const FileOfferFrame(
          sid: 's1',
          fid: '0011223344556677',
          name: 'rapport.pdf',
          size: 2048,
          group: 'aaaabbbbccccdddd',
        ),
      );
      session.receive(
        const FileOfferFrame(
          sid: 's1',
          fid: '1122334455667788',
          name: 'budget.xlsx',
          size: 1024,
          group: 'aaaabbbbccccdddd',
        ),
      );
    }

    testWidgets('one bubble, one validation', (tester) async {
      await pumpChat(tester);
      await offerTwo();
      await tester.pump();

      expect(
        find.byKey(const ValueKey('file-group-aaaabbbbccccdddd')),
        findsOneWidget,
      );
      expect(find.text('rapport.pdf'), findsOneWidget);
      expect(find.text('budget.xlsx'), findsOneWidget);
      expect(find.textContaining('2 fichiers (3 Ko)'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('file-accept-0011223344556677')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('group-accept-aaaabbbbccccdddd')),
        findsOneWidget,
      );
    });

    testWidgets('refusing everything leaves nothing to answer', (tester) async {
      await pumpChat(tester);
      await offerTwo();
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('group-decline-aaaabbbbccccdddd')),
      );
      await tester.pump();

      expect(sent.whereType<FileCancelFrame>(), hasLength(2));
      expect(
        find.byKey(const ValueKey('group-accept-aaaabbbbccccdddd')),
        findsNothing,
      );
    });

    testWidgets('images sent together open with the same validation', (
      tester,
    ) async {
      await pumpChat(tester);
      for (final id in ['0011223344556677', '1122334455667788']) {
        session.receive(
          ImageOfferFrame(
            sid: 's1',
            img: id,
            width: 4,
            height: 3,
            // A 1×1 JPEG is not needed here: the bubble tolerates garbage.
            preview: 'AAAA',
            group: 'aaaabbbbccccdddd',
          ),
        );
      }
      await tester.pump();
      expect(find.textContaining('2 images'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('group-accept-aaaabbbbccccdddd')),
      );
      await tester.pump();
      expect(sent.whereType<ImageRequestFrame>(), hasLength(2));
      tester.takeException();
    });
  });
}
