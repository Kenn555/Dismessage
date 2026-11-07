import 'dart:convert';

import 'package:dismessage/config.dart';
import 'package:dismessage/features/chat/chat_screen.dart';
import 'package:dismessage/services/chat_session.dart';
import 'package:dismessage/services/attachments.dart';
import 'package:dismessage/services/clipboard_images.dart';
import 'package:dismessage/services/connection_service.dart';
import 'package:dismessage/services/contacts_service.dart';
import 'package:dismessage/services/identity_service.dart';
import 'package:dismessage/services/image_codec.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'fakes.dart';

const peer = '318343691';

final jpeg = img.encodeJpg(img.Image(width: 40, height: 30));
final encoded = EncodedImage(bytes: jpeg, width: 40, height: 30, preview: jpeg);

void main() {
  late ChatSession session;
  late List<Frame> sent;

  Future<void> pumpChat(
    WidgetTester tester, {
    ImagePickerFn? pick,
    ImageEncoderFn? encode,
    ClipboardImages clipboard = const NoClipboardImages(),
  }) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = MemoryStore();
    sent = [];
    session = ChatSession(sid: 's1', peer: peer, send: sent.add);
    final connection = ConnectionService(
      identity: IdentityService(store),
      serverUri: ServerSettings(
        store,
        fallback: Uri.parse('ws://x/ws'),
      ).serverUri,
    );
    addTearDown(connection.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          session: session,
          connection: connection,
          contacts: ContactsService(store),
          pickImage: pick ?? (_) async => [jpeg],
          cameraAvailable: false,
          createCamera: () => null,
          encodeImage: encode ?? (_) async => encoded,
          createAudioBackend: FakeAudioBackend.new,
          clipboardImages: clipboard,
        ),
      ),
    );
  }

  group('several images', () {
    testWidgets('each chosen picture leaves as its own offer', (tester) async {
      await pumpChat(tester, pick: (_) async => [jpeg, jpeg, jpeg]);
      await tester.tap(find.byKey(const Key('send-image')));
      await tester.pump();
      await tester.pump();

      final offers = sent.whereType<ImageOfferFrame>().toList();
      expect(offers, hasLength(3));
      expect(offers.map((o) => o.img).toSet(), hasLength(3));
      expect(find.text('Pas encore ouverte'), findsNWidgets(3));
    });

    testWidgets('at most kMaxImagesPerSend leave, with a message', (
      tester,
    ) async {
      await pumpChat(
        tester,
        pick: (_) async => List.filled(kMaxImagesPerSend + 2, jpeg),
      );
      await tester.tap(find.byKey(const Key('send-image')));
      await tester.pump();
      await tester.pump();
      expect(sent.whereType<ImageOfferFrame>(), hasLength(kMaxImagesPerSend));
      expect(
        find.text(
          'Seules les $kMaxImagesPerSend premières images sont envoyées.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('one unreadable picture does not stop the others', (
      tester,
    ) async {
      final broken = Uint8List.fromList([1, 2, 3]);
      await pumpChat(
        tester,
        pick: (_) async => [jpeg, broken, jpeg],
        encode: (bytes) async => identical(bytes, broken)
            ? throw const ImageCodecException(
                'Format d’image non pris en charge.',
              )
            : encoded,
      );
      await tester.tap(find.byKey(const Key('send-image')));
      await tester.pump();
      await tester.pump();
      expect(sent.whereType<ImageOfferFrame>(), hasLength(2));
      expect(find.text('Format d’image non pris en charge.'), findsOneWidget);
    });
  });

  group('paste', () {
    Future<void> pressCtrlV(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('Ctrl+V shows the pictures, sent once confirmed', (
      tester,
    ) async {
      final clipboard = FakeClipboardImages()..images = [jpeg, jpeg];
      await pumpChat(tester, clipboard: clipboard);
      await tester.showKeyboard(find.byKey(const Key('chat-input')));
      await pressCtrlV(tester);

      expect(find.byKey(const Key('paste-dialog')), findsOneWidget);
      expect(find.text('Envoyer 2 images ?'), findsOneWidget);
      expect(sent.whereType<ImageOfferFrame>(), isEmpty);

      await tester.tap(find.byKey(const Key('paste-send')));
      await tester.pumpAndSettle();
      expect(sent.whereType<ImageOfferFrame>(), hasLength(2));
    });

    testWidgets('a cancelled paste sends nothing', (tester) async {
      final clipboard = FakeClipboardImages()..images = [jpeg];
      await pumpChat(tester, clipboard: clipboard);
      await tester.showKeyboard(find.byKey(const Key('chat-input')));
      await pressCtrlV(tester);
      expect(find.text('Envoyer l’image ?'), findsOneWidget);

      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('paste-dialog')), findsNothing);
      expect(sent.whereType<ImageOfferFrame>(), isEmpty);
    });

    testWidgets('Ctrl+V without a picture pastes the text at the cursor', (
      tester,
    ) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async =>
            call.method == 'Clipboard.getData' ? {'text': 'collé '} : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pumpChat(tester, clipboard: FakeClipboardImages());
      await tester.enterText(find.byKey(const Key('chat-input')), 'Texte');
      final input = tester.widget<TextField>(
        find.byKey(const Key('chat-input')),
      );
      input.controller!.selection = const TextSelection.collapsed(offset: 0);
      await pressCtrlV(tester);
      await tester.pump(const Duration(milliseconds: kDraftBatchMs * 2));

      expect(find.byKey(const Key('paste-dialog')), findsNothing);
      expect(input.controller!.text, 'collé Texte');
      final streamed = sent.whereType<DraftOpsFrame>().expand((f) => f.ops);
      expect(TextDiff.applyAll('', streamed), 'collé Texte');
    });

    testWidgets('pictures pasted in the browser ask for confirmation', (
      tester,
    ) async {
      final clipboard = FakeClipboardImages();
      await pumpChat(tester, clipboard: clipboard);
      // Not focused: the paste was meant for something else.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      clipboard.paste([jpeg]);
      await tester.pump();
      expect(find.byKey(const Key('paste-dialog')), findsNothing);

      await tester.showKeyboard(find.byKey(const Key('chat-input')));
      clipboard.paste([jpeg]);
      await tester.pump();
      await tester.tap(find.byKey(const Key('paste-send')));
      await tester.pumpAndSettle();
      expect(sent.whereType<ImageOfferFrame>(), hasLength(1));
    });
  });

  group('images', () {
    testWidgets('sending shows my image with "Pas encore ouverte"', (
      tester,
    ) async {
      await pumpChat(tester);
      await tester.tap(find.byKey(const Key('send-image')));
      await tester.pump();
      await tester.pump();

      final offer = sent.whereType<ImageOfferFrame>().single;
      expect((offer.width, offer.height), (40, 30));
      expect(find.text('Pas encore ouverte'), findsOneWidget);
      expect(find.text('Appuyer pour voir'), findsNothing);

      // The peer opens it: the full image leaves and the receipt updates.
      session.receive(ImageRequestFrame(sid: 's1', img: offer.img));
      await tester.pump();
      expect(sent.whereType<ImageDataFrame>(), hasLength(1));
      expect(find.text('Ouverte'), findsOneWidget);
    });

    testWidgets('a received image is blurred until tapped', (tester) async {
      await pumpChat(tester);
      session.receive(
        ImageOfferFrame(
          sid: 's1',
          img: '0123456789abcdef',
          width: 40,
          height: 30,
          preview: _b64(jpeg),
        ),
      );
      await tester.pump();
      expect(find.text('Appuyer pour voir'), findsOneWidget);
      expect(find.byType(ImageFiltered), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('image-0123456789abcdef')));
      await tester.pump();
      expect(
        sent.whereType<ImageRequestFrame>().single.img,
        '0123456789abcdef',
      );
      expect(find.text('Ouverture…'), findsOneWidget);

      session.receive(
        ImageDataFrame(sid: 's1', img: '0123456789abcdef', data: _b64(jpeg)),
      );
      await tester.pump();
      expect(find.text('Appuyer pour voir'), findsNothing);
      expect(find.text('Ouverture…'), findsNothing);
      expect(find.byType(ImageFiltered), findsNothing);
    });

    testWidgets('cancelling the picker sends nothing', (tester) async {
      await pumpChat(tester, pick: (_) async => []);
      await tester.tap(find.byKey(const Key('send-image')));
      await tester.pump();
      expect(sent, isEmpty);
    });

    testWidgets('unsupported pictures show a clear message', (tester) async {
      await pumpChat(
        tester,
        encode: (_) async => throw const ImageCodecException(
          'Format d’image non pris en charge.',
        ),
      );
      await tester.tap(find.byKey(const Key('send-image')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Format d’image non pris en charge.'), findsOneWidget);
      expect(sent, isEmpty);
    });
  });

  group('emojis', () {
    testWidgets('picking an emoji inserts it and streams it live', (
      tester,
    ) async {
      await pumpChat(tester);
      await tester.enterText(find.byKey(const Key('chat-input')), 'Salut ');
      await tester.tap(find.byKey(const Key('emoji-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('emoji-😀')));
      await tester.pump(const Duration(milliseconds: kDraftBatchMs * 2));

      final input = tester.widget<TextField>(
        find.byKey(const Key('chat-input')),
      );
      expect(input.controller!.text, 'Salut 😀');
      final streamed = sent.whereType<DraftOpsFrame>().expand((f) => f.ops);
      expect(TextDiff.applyAll('', streamed), 'Salut 😀');
    });

    testWidgets('emoji is inserted at the cursor', (tester) async {
      await pumpChat(tester);
      await tester.enterText(find.byKey(const Key('chat-input')), 'ab');
      final input = tester.widget<TextField>(
        find.byKey(const Key('chat-input')),
      );
      input.controller!.selection = const TextSelection.collapsed(offset: 1);
      await tester.tap(find.byKey(const Key('emoji-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('emoji-😉')));
      await tester.pump(const Duration(milliseconds: kDraftBatchMs * 2));
      expect(input.controller!.text, 'a😉b');
    });

    testWidgets('the panel toggles', (tester) async {
      await pumpChat(tester);
      expect(find.byKey(const ValueKey('emoji-😀')), findsNothing);
      await tester.tap(find.byKey(const Key('emoji-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('emoji-😀')), findsOneWidget);
      await tester.tap(find.byKey(const Key('emoji-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('emoji-😀')), findsNothing);
    });
  });
}

String _b64(Uint8List bytes) => base64Encode(bytes);
