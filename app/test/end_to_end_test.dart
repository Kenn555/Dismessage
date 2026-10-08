// End-to-end: two real ConnectionServices talking through a real relay.
// Plain `test` (no widget binding) so that real sockets and timers are used.
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
import 'package:web_socket_channel/web_socket_channel.dart';

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

/// A real connection that records every text the app puts on the wire.
class SpyChannel implements WebSocketChannel {
  SpyChannel(this._inner);
  final WebSocketChannel _inner;
  final sent = <String>[];

  @override
  late final WebSocketSink sink = _SpySink(_inner.sink, sent);

  @override
  Future<void> get ready => _inner.ready;

  @override
  Stream<dynamic> get stream => _inner.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SpySink implements WebSocketSink {
  _SpySink(this._inner, this._sent);
  final WebSocketSink _inner;
  final List<String> _sent;

  @override
  void add(Object? data) {
    _sent.add(data as String);
    _inner.add(data);
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) =>
      _inner.close(closeCode, closeReason);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

  test('nothing readable crosses the relay, and both see one code', () async {
    final spies = <SpyChannel>[];
    Future<ConnectionService> spied() async {
      final service = ConnectionService(
        identity: IdentityService(MemoryStore()),
        serverUri: Uri.parse('ws://localhost:${server.port}/ws'),
        connect: (uri) {
          final spy = SpyChannel(WebSocketChannel.connect(uri));
          spies.add(spy);
          return spy;
        },
      );
      services.add(service);
      await service.start();
      await waitFor(() => service.status == ServerStatus.online);
      return service;
    }

    final a = await spied();
    final b = await spied();
    await pair(a, b);
    final mine = a.sessions.single;
    final theirs = b.sessions.single;
    await waitFor(() => a.isEncrypted(mine) && b.isEncrypted(theirs));

    mine.updateDraft('Le code du coffre est 4321');
    await waitFor(() => theirs.remoteDraft == 'Le code du coffre est 4321');
    expect(mine.sendMessage(), isTrue);
    await waitFor(() => theirs.messages.isNotEmpty, reason: 'message');

    final wire = spies.expand((s) => s.sent).join(' ');
    expect(wire, isNot(contains('coffre')));
    expect(wire, isNot(contains('4321')));
    expect(wire, contains('"t":"sealed"'));
    final code = await a.safetyCode(mine);
    expect(code, isNotNull);
    expect(await b.safetyCode(theirs), code);
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

  test(
    'each relay gives its own ID, found again when switching back',
    () async {
      final other = await serve(
        Relay(IdStore.memory()),
        address: 'localhost',
        port: 0,
      );
      addTearDown(() => other.close(force: true));
      final store = MemoryStore();
      final first = await startClient(store);
      final id = first.myId!;

      await first.setServerUri(Uri.parse('ws://localhost:${other.port}/ws'));
      await waitFor(
        () => first.status == ServerStatus.online && first.myId != id,
        reason: 'online on the other relay, with its ID',
      );
      await first.setServerUri(Uri.parse('ws://localhost:${server.port}/ws'));
      await waitFor(
        () => first.status == ServerStatus.online && first.myId == id,
        reason: 'back with the first ID',
      );
    },
  );

  test('the ID survives a relay restart that loses its store', () async {
    final signer = IdSigner.random();
    await server.close(force: true);
    server = await serve(
      Relay(IdStore.memory(), signer: signer),
      address: 'localhost',
      port: 0,
    );
    final port = server.port;
    final store = MemoryStore();
    final a = await startClient(store);
    final id = a.myId!;

    // Render Free: the store is gone, the key (environment) is not.
    a.suspend();
    await server.close(force: true);
    server = await serve(
      Relay(IdStore.memory(), signer: signer),
      address: 'localhost',
      port: port,
    );
    await a.resume();
    await waitFor(() => a.status == ServerStatus.online, reason: 'back');
    expect(a.myId, id);
  });

  group('the own ID of an older version', () {
    MemoryStore olderStore() => MemoryStore()
      ..values[IdentityService.idKey] = '482913075'
      ..values[IdentityService.secretKey] = 'chosen-by-the-app';

    test('is kept and signed by a relay that accepts it', () async {
      await server.close(force: true);
      server = await serve(
        Relay(IdStore.memory(), acceptLegacyIds: true),
        address: 'localhost',
        port: 0,
      );
      final store = olderStore();
      final a = await startClient(store);
      expect(a.myId, '482913075');
      final relay = Uri.parse('ws://localhost:${server.port}/ws');
      await waitFor(
        () => store.values[IdentityService.secretKeyFor(relay)] != null,
        reason: 'signed secret saved',
      );
      expect(
        store.values[IdentityService.secretKeyFor(relay)],
        isNot('chosen-by-the-app'),
      );
    });

    test('is replaced by a relay that does not accept it', () async {
      final a = await startClient(olderStore());
      expect(a.myId, isNot('482913075'));
      expect(DismessageId.isValid(a.myId!), isTrue);
    });
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
