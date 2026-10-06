import 'dart:typed_data';

import 'package:dismessage/config.dart';
import 'package:dismessage/features/chat/chat_screen.dart';
import 'package:dismessage/services/chat_session.dart';
import 'package:dismessage/services/connection_service.dart';
import 'package:dismessage/services/contacts_service.dart';
import 'package:dismessage/services/file_storage.dart';
import 'package:dismessage/services/identity_service.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const peer = '318343691';
const fid = '0011223344556677';

void main() {
  late ChatSession session;
  late List<Frame> sent;
  late MemoryFileStorage disk;

  Future<void> pumpChat(WidgetTester tester, {FilePickerFn? pick}) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = MemoryStore();
    sent = [];
    disk = MemoryFileStorage();
    session = ChatSession(sid: 's1', peer: peer, send: sent.add, files: disk);
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
          cameraAvailable: false,
          createCamera: () => null,
          createAudioBackend: FakeAudioBackend.new,
          pickFile: pick ?? () async => null,
        ),
      ),
    );
  }

  void offer({int size = 3}) {
    session.receive(
      FileOfferFrame(sid: 's1', fid: fid, name: 'Contrat.pdf', size: size),
    );
  }

  testWidgets('the paperclip offers the chosen file', (tester) async {
    final file = FakeChosenFile('Budget 2026.xlsx', Uint8List(2048));
    await pumpChat(tester, pick: () async => file);

    await tester.tap(find.byKey(const Key('send-file')));
    await tester.pump();

    final frame = sent.whereType<FileOfferFrame>().single;
    expect((frame.name, frame.size), ('Budget 2026.xlsx', 2048));
    expect(find.text('Budget 2026.xlsx'), findsOneWidget);
    expect(find.textContaining('En attente de confirmation'), findsOneWidget);
    expect(find.byKey(ValueKey('file-cancel-${frame.fid}')), findsOneWidget);
    expect(file.reads, isEmpty);
  });

  testWidgets('the sender can withdraw the offer', (tester) async {
    final file = FakeChosenFile('a.txt', Uint8List(10));
    await pumpChat(tester, pick: () async => file);
    await tester.tap(find.byKey(const Key('send-file')));
    await tester.pump();
    final id = sent.whereType<FileOfferFrame>().single.fid;

    await tester.tap(find.byKey(ValueKey('file-cancel-$id')));
    await tester.pump();

    expect(sent.last, isA<FileCancelFrame>());
    expect(find.textContaining('Transfert annulé'), findsOneWidget);
    expect(file.closed, isTrue);
  });

  testWidgets('a file over the limit is refused with its size', (tester) async {
    final big = FakeChosenFile(
      'film.mkv',
      Uint8List(1),
      size: kMaxFileBytes + 1,
    );
    await pumpChat(tester, pick: () async => big);

    await tester.tap(find.byKey(const Key('send-file')));
    await tester.pump();

    expect(sent, isEmpty);
    expect(find.textContaining('Fichier trop volumineux'), findsOneWidget);
    expect(big.closed, isTrue);
  });

  testWidgets('cancelling the chooser sends nothing', (tester) async {
    await pumpChat(tester);
    await tester.tap(find.byKey(const Key('send-file')));
    await tester.pump();
    expect(sent, isEmpty);
  });

  testWidgets('a chooser error is shown', (tester) async {
    await pumpChat(
      tester,
      pick: () async => throw const FileStorageException('Accès refusé'),
    );
    await tester.tap(find.byKey(const Key('send-file')));
    await tester.pump();
    expect(find.textContaining('Accès refusé'), findsOneWidget);
  });

  testWidgets('the receiver is asked before anything is saved', (tester) async {
    await pumpChat(tester);
    offer(size: 3 * 1024 * 1024);
    await tester.pump();

    expect(find.text('Contrat.pdf'), findsOneWidget);
    expect(find.textContaining('3 Mo'), findsOneWidget);
    expect(find.textContaining('Vous propose ce fichier'), findsOneWidget);
    expect(find.byKey(const ValueKey('file-accept-$fid')), findsOneWidget);
    expect(find.byKey(const ValueKey('file-decline-$fid')), findsOneWidget);
    expect(disk.sinks, isEmpty);
  });

  testWidgets('refusing tells the sender', (tester) async {
    await pumpChat(tester);
    offer();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('file-decline-$fid')));
    await tester.pump();

    expect(sent.single, isA<FileCancelFrame>());
    expect(find.textContaining('Vous avez refusé'), findsOneWidget);
    expect(find.byKey(const ValueKey('file-accept-$fid')), findsNothing);
    expect(disk.sinks, isEmpty);
  });

  testWidgets('accepting saves the file as it comes, then offers to open '
      'it', (tester) async {
    await pumpChat(tester);
    offer(size: kFileChunkBytes + 3);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('file-accept-$fid')));
    await tester.pump();
    expect(sent.single, isA<FileAcceptFrame>());

    session.receive(
      FileChunkFrame(
        sid: 's1',
        fid: fid,
        index: 0,
        data: 'A' * (kFileChunkBytes ~/ 3 * 4),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('192 Ko /'), findsOneWidget);
    expect(find.byKey(const ValueKey('file-cancel-$fid')), findsOneWidget);

    session.receive(
      const FileChunkFrame(sid: 's1', fid: fid, index: 1, data: 'AAAA'),
    );
    await tester.pump();
    await tester.pump();

    expect(disk.sinks.single.closed, isTrue);
    expect(sent.whereType<FileAckFrame>().map((f) => f.count), [1, 2]);
    expect(
      find.textContaining('Enregistré dans Téléchargements'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('file-open-$fid')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('file-folder-$fid')));
    await tester.pump();
    final saved = (session.byId(fid)! as ChatFile).saved! as FakeSavedFile;
    expect((saved.opened, saved.shown), (1, 1));
  });

  testWidgets('a disk error is shown on the bubble', (tester) async {
    await pumpChat(tester);
    disk.createError = 'Dossier Téléchargements introuvable.';
    offer();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('file-accept-$fid')));
    await tester.pump();
    await tester.pump();
    expect(
      find.textContaining('Échec : Dossier Téléchargements'),
      findsOneWidget,
    );
    expect(sent.single, isA<FileCancelFrame>());
  });

  testWidgets('once the peer left, the offer can no longer be accepted', (
    tester,
  ) async {
    await pumpChat(tester);
    offer();
    session.markPeerLeft();
    await tester.pump();
    expect(find.textContaining('Transfert annulé'), findsOneWidget);
    expect(find.byKey(const ValueKey('file-accept-$fid')), findsNothing);
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byIcon(Icons.attach_file_rounded),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
    );
  });
}
