import 'dart:convert';
import 'dart:typed_data';

import 'package:dismessage/config.dart';
import 'package:dismessage/features/chat/chat_screen.dart';
import 'package:dismessage/services/chat_session.dart';
import 'package:dismessage/services/connection_service.dart';
import 'package:dismessage/services/contacts_service.dart';
import 'package:dismessage/services/identity_service.dart';
import 'package:dismessage/services/image_codec.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/material.dart';
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
          pickImage: pick ?? (_) async => jpeg,
          cameraAvailable: false,
          encodeImage: encode ?? (_) async => encoded,
          createAudioBackend: FakeAudioBackend.new,
        ),
      ),
    );
  }

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
      await pumpChat(tester, pick: (_) async => null);
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
