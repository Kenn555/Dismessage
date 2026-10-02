// End-to-end: two real ConnectionServices talking through a real relay.
// Plain `test` (no widget binding) so that real sockets and timers are used.
import 'dart:async';
import 'dart:io';

import 'package:dismessage/services/chat_session.dart';
import 'package:dismessage/services/connection_service.dart';
import 'package:dismessage/services/identity_service.dart';
import 'package:dismessage/services/image_codec.dart';
import 'package:dismessage_server/dismessage_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

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

  Future<ConnectionService> startClient([MemoryStore? store]) async {
    final service = ConnectionService(
      identity: IdentityService(store ?? MemoryStore()),
      serverUri: Uri.parse('ws://localhost:${server.port}/ws'),
      reconnectDelay: const Duration(milliseconds: 100),
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
      () => a.session != null && b.session != null,
      reason: 'session started',
    );
    await sub.cancel();
    expect(a.session!.peer, b.myId);
    expect(b.session!.peer, a.myId);
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

  test('B sees A typing live, then receives the message', () async {
    final a = await startClient();
    final b = await startClient();
    await pair(a, b);

    final seenByB = <String>[];
    b.session!.addListener(() {
      final draft = b.session!.remoteDraft;
      if (seenByB.isEmpty || seenByB.last != draft) seenByB.add(draft);
    });

    const typed = 'Bonjour 👋';
    final chars = typed.runes.map(String.fromCharCode).toList();
    for (var i = 1; i <= chars.length; i++) {
      a.session!.updateDraft(chars.take(i).join());
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    await waitFor(() => b.session!.remoteDraft == typed, reason: 'live draft');

    // B saw the text grow progressively, never something else.
    expect(seenByB.length, greaterThan(3));
    for (final snapshot in seenByB) {
      expect(typed.startsWith(snapshot), isTrue, reason: snapshot);
    }

    expect(a.session!.sendMessage(), isTrue);
    await waitFor(() => b.session!.messages.isNotEmpty, reason: 'message');
    expect((b.session!.messages.single as ChatMessage).text, typed);
    expect(b.session!.messages.single.fromMe, isFalse);
    expect(b.session!.remoteDraft, '');
    expect(a.session!.messages.single.fromMe, isTrue);
  });

  test('corrections in the middle are mirrored', () async {
    final a = await startClient();
    final b = await startClient();
    await pair(a, b);
    for (final t in ['le chat', 'le chat noir', 'le chien noir', 'le chien']) {
      a.session!.updateDraft(t);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await waitFor(() => b.session!.remoteDraft == 'le chien');
    a.session!.updateDraft('');
    await waitFor(() => b.session!.remoteDraft == '', reason: 'cleared');
  });

  test('leaving the chat notifies the peer', () async {
    final a = await startClient();
    final b = await startClient();
    await pair(a, b);
    a.leaveSession();
    await waitFor(() => b.session!.peerLeft, reason: 'peer left');
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
    final sent = a.session!.sendImage(encoded)!;

    await waitFor(() => b.session!.messages.isNotEmpty, reason: 'offer');
    final received = b.session!.messages.single as ChatImage;
    expect(received.status, ImageStatus.blurred);
    expect(received.bytes, isNull);

    b.session!.openImage(received);
    await waitFor(
      () => received.status == ImageStatus.opened,
      reason: 'full image',
    );
    expect(received.bytes, encoded.bytes);
    await waitFor(() => sent.status == ImageStatus.opened, reason: 'receipt');
  });
}
