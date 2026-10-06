// End-to-end: two real ConnectionServices talking through a real relay.
// Plain `test` (no widget binding) so that real sockets and timers are used.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dismessage/services/chat_session.dart';
import 'package:dismessage/services/connection_service.dart';
import 'package:dismessage/services/file_storage.dart';
import 'package:dismessage/services/file_storage_io.dart';
import 'package:dismessage/services/identity_service.dart';
import 'package:dismessage/services/image_codec.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:dismessage_server/dismessage_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'fakes.dart';

Future<void> waitFor(bool Function() condition, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for ${reason ?? 'condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late HttpServer server;
  final services = <ConnectionService>[];

  Future<ConnectionService> startClient([
    MemoryStore? store,
    FileStorage? files,
  ]) async {
    final service = ConnectionService(
      identity: IdentityService(store ?? MemoryStore()),
      serverUri: Uri.parse('ws://localhost:${server.port}/ws'),
      reconnectDelay: const Duration(milliseconds: 100),
      fileStorage: files,
    );
    services.add(service);
    await service.start();
    await waitFor(
      () => service.status == ServerStatus.online,
      reason: 'client online',
    );
    return service;
  }

  /// A asks B; B accepts. Returns once both have the session.
  Future<void> pair(ConnectionService a, ConnectionService b) async {
    final sub = b.events.listen((event) {
      if (event is IncomingRequestEvent) b.accept(event.from);
    });
    a.requestChat(b.myId!);
    await waitFor(
      () => a.sessions.isNotEmpty && b.sessions.isNotEmpty,
      reason: 'session started',
    );
    await sub.cancel();
    expect(a.sessions.single.peer, b.myId);
    expect(b.sessions.single.peer, a.myId);
  }

  setUp(() async {
    server = await serve(
      Relay(IdStore.memory()),
      address: 'localhost',
      port: 0,
    );
  });

  tearDown(() async {
    for (final s in services) {
      s.dispose();
    }
    services.clear();
    await server.close(force: true);
  });

  test('A talks to B and C at the same time, isolated', () async {
    final a = await startClient();
    final b = await startClient();
    final c = await startClient();
    await pair(a, b);
    // C asks A while A is talking to B.
    final sub = a.events.listen((event) {
      if (event is IncomingRequestEvent) a.accept(event.from);
    });
    c.requestChat(a.myId!);
    await waitFor(() => a.sessions.length == 2 && c.sessions.isNotEmpty);
    await sub.cancel();

    final withB = a.liveSessionWith(b.myId!)!;
    final withC = a.liveSessionWith(c.myId!)!;
    expect(withB.peerLeft, isFalse, reason: 'B is still there');
    b.sessions.single.updateDraft('pour A de B');
    c.sessions.single.updateDraft('pour A de C');
    await waitFor(
      () =>
          withB.remoteDraft == 'pour A de B' &&
          withC.remoteDraft == 'pour A de C',
      reason: 'both drafts',
    );

    withC.updateDraft('réponse à C');
    expect(withC.sendMessage(), isTrue);
    await waitFor(() => c.sessions.single.messages.isNotEmpty);
    expect(b.sessions.single.messages, isEmpty);

    a.closeSession(withB);
    await waitFor(() => b.sessions.single.peerLeft, reason: 'B told');
    expect(c.sessions.single.peerLeft, isFalse);
  });

  test('B sees A typing live, then receives the message', () async {
    final a = await startClient();
    final b = await startClient();
    await pair(a, b);

    final seenByB = <String>[];
    b.sessions.single.addListener(() {
      final draft = b.sessions.single.remoteDraft;
      if (seenByB.isEmpty || seenByB.last != draft) seenByB.add(draft);
    });

    const typed = 'Bonjour 👋';
    final chars = typed.runes.map(String.fromCharCode).toList();
    for (var i = 1; i <= chars.length; i++) {
      a.sessions.single.updateDraft(chars.take(i).join());
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    await waitFor(
      () => b.sessions.single.remoteDraft == typed,
      reason: 'live draft',
    );

    // B saw the text grow progressively, never something else.
    expect(seenByB.length, greaterThan(3));
    for (final snapshot in seenByB) {
      expect(typed.startsWith(snapshot), isTrue, reason: snapshot);
    }

    expect(a.sessions.single.sendMessage(), isTrue);
    await waitFor(
      () => b.sessions.single.messages.isNotEmpty,
      reason: 'message',
    );
    expect((b.sessions.single.messages.single as ChatMessage).text, typed);
    expect(b.sessions.single.messages.single.fromMe, isFalse);
    expect(b.sessions.single.remoteDraft, '');
    expect(a.sessions.single.messages.single.fromMe, isTrue);
  });

  test('corrections in the middle are mirrored', () async {
    final a = await startClient();
    final b = await startClient();
    await pair(a, b);
    for (final t in ['le chat', 'le chat noir', 'le chien noir', 'le chien']) {
      a.sessions.single.updateDraft(t);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await waitFor(() => b.sessions.single.remoteDraft == 'le chien');
    a.sessions.single.updateDraft('');
    await waitFor(() => b.sessions.single.remoteDraft == '', reason: 'cleared');
  });

  test('leaving the chat notifies the peer', () async {
    final a = await startClient();
    final b = await startClient();
    await pair(a, b);
    a.closeSession(a.sessions.single);
    await waitFor(() => b.sessions.single.peerLeft, reason: 'peer left');
  });

  test('the ID survives a restart of the app', () async {
    final store = MemoryStore();
    final first = await startClient(store);
    final id = first.myId;
    first.dispose();
    services.remove(first);
    final again = await startClient(store);
    expect(again.myId, id);
  });

  test('a regenerated ID replaces the old one', () async {
    final a = await startClient();
    final b = await startClient();
    final oldId = a.myId!;
    await a.regenerateId();
    await waitFor(() => a.status == ServerStatus.online && a.myId != oldId);

    final events = <Object>[];
    final sub = b.events.listen(events.add);
    b.requestChat(oldId);
    await waitFor(() => events.isNotEmpty, reason: 'answer about old ID');
    expect(events.single, isA<PeerOfflineEvent>());
    await sub.cancel();

    await pair(b, a);
  });

  test('switching server at runtime reconnects with the same ID', () async {
    final store = MemoryStore();
    final service = ConnectionService(
      identity: IdentityService(store),
      serverUri: Uri.parse('ws://localhost:1/ws'), // nothing listens here
      reconnectDelay: const Duration(milliseconds: 50),
    );
    services.add(service);
    unawaited(service.start());
    await waitFor(() => service.myId != null, reason: 'identity loaded');
    final id = service.myId;
    expect(service.status, isNot(ServerStatus.online));

    await service.setServerUri(Uri.parse('ws://localhost:${server.port}/ws'));
    await waitFor(
      () => service.status == ServerStatus.online,
      reason: 'online on the new server',
    );
    expect(service.myId, id);
  });

  test('cancelling a request closes it on the other side', () async {
    final a = await startClient();
    final b = await startClient();
    final received = <ConnectionEvent>[];
    final sub = b.events.listen(received.add);

    a.requestChat(b.myId!);
    expect(a.pendingRequest, b.myId);
    await waitFor(() => received.whereType<IncomingRequestEvent>().isNotEmpty);

    a.cancelRequest();
    expect(a.pendingRequest, isNull);
    await waitFor(
      () => received.whereType<RequestCancelledEvent>().isNotEmpty,
      reason: 'cancel reaches B',
    );
    expect(received.whereType<RequestCancelledEvent>().single.from, a.myId);
    await sub.cancel();
  });

  test('pending request is cleared once the session starts', () async {
    final a = await startClient();
    final b = await startClient();
    await pair(a, b);
    expect(a.pendingRequest, isNull);
  });

  test('a real photo goes through the relay only once opened', () async {
    final a = await startClient();
    final b = await startClient();
    await pair(a, b);

    // A noisy 1600x1200 picture: compresses badly, close to the size limit.
    final picture = img.Image(width: 1600, height: 1200);
    var seed = 3;
    for (final pixel in picture) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      pixel
        ..r = seed & 0xff
        ..g = (seed >> 8) & 0xff
        ..b = (seed >> 16) & 0xff;
    }
    final encoded = ImageCodec.encode(img.encodePng(picture));
    final sent = a.sessions.single.sendImage(encoded)!;

    await waitFor(() => b.sessions.single.messages.isNotEmpty, reason: 'offer');
    final received = b.sessions.single.messages.single as ChatImage;
    expect(received.status, ImageStatus.blurred);
    expect(received.bytes, isNull);

    b.sessions.single.openImage(received);
    await waitFor(
      () => received.status == ImageStatus.opened,
      reason: 'full image',
    );
    expect(received.bytes, encoded.bytes);
    await waitFor(() => sent.status == ImageStatus.opened, reason: 'receipt');
  });

  test(
    'a file goes to the receiver disk once accepted, typing still live',
    () async {
      final downloads = Directory.systemTemp.createTempSync('dismessage_e2e_');
      addTearDown(() => downloads.deleteSync(recursive: true));
      final a = await startClient();
      final b = await startClient(
        null,
        DesktopFileStorage(directory: () async => downloads),
      );
      await pair(a, b);

      final bytes = Uint8List.fromList(
        List.generate(kFileChunkBytes * 12 + 4321, (i) => (i * 31 + 7) % 256),
      );
      final sent = a.sessions.single.sendFile(
        FakeChosenFile('Présentation finale.pptx', bytes),
      )!;
      await waitFor(
        () => b.sessions.single.messages.isNotEmpty,
        reason: 'offer',
      );
      final received = b.sessions.single.messages.single as ChatFile;
      expect(received.status, FileStatus.awaiting);
      expect(downloads.listSync(), isEmpty);

      await b.sessions.single.acceptFile(received);
      // Typing keeps flowing during the transfer.
      a.sessions.single.updateDraft('ça arrive');
      await waitFor(
        () => b.sessions.single.remoteDraft == 'ça arrive',
        reason: 'live typing during the transfer',
      );
      await waitFor(
        () => sent.status == FileStatus.done,
        reason: 'sender told the file is saved',
      );
      expect(received.status, FileStatus.done);
      final saved = File(
        '${downloads.path}${Platform.pathSeparator}Présentation finale.pptx',
      );
      expect(saved.readAsBytesSync(), bytes);
      expect(downloads.listSync(), hasLength(1), reason: 'no .part left');
    },
  );
}
