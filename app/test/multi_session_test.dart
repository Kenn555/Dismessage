import 'package:dismessage/services/chat_session.dart';
import 'package:dismessage/services/connection_service.dart';
import 'package:dismessage/services/identity_service.dart';
import 'package:dismessage/services/live_link.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const me = '482913075';
const alice = '318343691';
const bob = '555666777';

void main() {
  late ScriptedChannel channel;
  late ConnectionService connection;

  /// The channel of the next connection.
  late ScriptedChannel Function() nextChannel;

  setUp(() async {
    channel = ScriptedChannel();
    nextChannel = () => channel;
    final store = MemoryStore()
      ..values[IdentityService.idKey] = me
      ..values[IdentityService.secretKey] = 'secret';
    connection = ConnectionService(
      identity: IdentityService(store),
      serverUri: Uri.parse('ws://test/ws'),
      connect: (_) => nextChannel(),
      reconnectDelay: const Duration(hours: 1),
      sessionGrace: const Duration(milliseconds: 500),
    );
    await connection.start();
    channel.receive(const RegisteredFrame(id: me));
    await channel.startSession('s1', alice);
    await channel.startSession('s2', bob);
    await pumpEventQueue();
  });

  tearDown(() => connection.dispose());

  ChatSession withPeer(String peer) =>
      connection.sessions.singleWhere((s) => s.peer == peer);

  /// What the relay passes on; conversation frames sealed by the peer.
  Future<void> receive(Frame frame) async {
    switch (frame) {
      case SessionStartedFrame(:final sid, :final peer):
        await channel.startSession(sid, peer);
      case RelayedFrame():
        await channel.receiveSecure(frame);
      default:
        channel.receive(frame);
    }
    await pumpEventQueue();
  }

  test('a new session does not end the previous one', () {
    expect(connection.sessions.map((s) => s.sid), ['s1', 's2']);
    expect(connection.sessions.every((s) => !s.peerLeft), isTrue);
    expect(channel.sink.sent.whereType<SessionLeaveFrame>(), isEmpty);
    expect(connection.active?.sid, 's2', reason: 'the newest is shown');
    expect(connection.liveSessionWith(alice)?.sid, 's1');
  });

  test('frames are routed by session', () async {
    await receive(const DraftSnapshotFrame(sid: 's1', seq: 1, text: 'Salut'));
    expect(withPeer(alice).remoteDraft, 'Salut');
    expect(withPeer(bob).remoteDraft, '');
    await receive(
      const MessageCommitFrame(
        sid: 's2',
        seq: 1,
        text: 'Yo',
        mid: '1111222233334444',
      ),
    );
    expect(withPeer(bob).messages, hasLength(1));
    expect(withPeer(alice).messages, isEmpty);
  });

  test('a conversation frame in clear is never trusted', () async {
    // The relay (or someone pretending to be the peer) without the keys.
    channel.receive(const DraftSnapshotFrame(sid: 's1', seq: 1, text: 'Faux'));
    channel.receive(
      const MessageCommitFrame(
        sid: 's1',
        seq: 2,
        text: 'Faux',
        mid: '1111222233334444',
      ),
    );
    await pumpEventQueue();
    expect(withPeer(alice).remoteDraft, '');
    expect(withPeer(alice).messages, isEmpty);
    // Our own frames only leave sealed.
    withPeer(alice).updateDraft('Bonjour');
    await Future<void>.delayed(const Duration(milliseconds: kDraftBatchMs * 3));
    expect(
      channel.sink.sent.whereType<RelayedFrame>().where(
        (f) => f is! SealedFrame && f is! KeyOfferFrame,
      ),
      isEmpty,
    );
    final opened = await channel.openedSent('s1');
    expect(opened.whereType<DraftOpsFrame>(), isNotEmpty);
  });

  test('unread counts only peer bubbles of hidden conversations', () async {
    await receive(const DraftSnapshotFrame(sid: 's1', seq: 1, text: 'Sal'));
    expect(withPeer(alice).unread, 0, reason: 'typing is not a message');
    await receive(
      const MessageCommitFrame(
        sid: 's1',
        seq: 2,
        text: 'Salut',
        mid: 'aaaabbbbccccdddd',
      ),
    );
    await receive(
      const MessageCommitFrame(
        sid: 's2',
        seq: 1,
        text: 'Yo',
        mid: '1111222233334444',
      ),
    );
    expect(withPeer(alice).unread, 1);
    expect(withPeer(bob).unread, 0, reason: 'on screen');
    connection.activate(withPeer(alice));
    expect(withPeer(alice).unread, 0);
    expect(withPeer(bob).viewing, isFalse);
  });

  test('peer_left ends only its session', () async {
    await receive(const PeerLeftFrame(sid: 's1'));
    expect(withPeer(alice).peerLeft, isTrue);
    expect(withPeer(bob).peerLeft, isFalse);
    expect(connection.liveSessionWith(alice), isNull);
  });

  test('closing leaves the session and shows the most recent one', () {
    connection.activate(withPeer(alice));
    connection.closeSession(withPeer(alice));
    expect(channel.sink.sent.whereType<SessionLeaveFrame>().single.sid, 's1');
    expect(connection.sessions.map((s) => s.sid), ['s2']);
    expect(connection.active?.sid, 's2');
  });

  test('closing an ended session sends nothing', () async {
    await receive(const PeerLeftFrame(sid: 's1'));
    connection.closeSession(withPeer(alice));
    expect(channel.sink.sent.whereType<SessionLeaveFrame>(), isEmpty);
  });

  test('a new session with the same peer replaces the old one', () async {
    await receive(const PeerLeftFrame(sid: 's1'));
    await receive(const SessionStartedFrame(sid: 's3', peer: alice));
    expect(connection.sessions.map((s) => s.sid), ['s3', 's2']);
    expect(connection.active?.sid, 's3');
  });

  group('lost connection', () {
    test('the conversations wait for it', () async {
      await channel.server.close();
      await pumpEventQueue();
      expect(connection.sessions.any((s) => s.peerLeft), isFalse);
      expect(connection.sessions.every((s) => s.meAway), isTrue);
      expect(withPeer(alice).reconnecting, isTrue);
    });

    test('back in time: they go on, and what was written leaves', () async {
      // Alice has our key (sent on the first connection).
      await channel.peerSafetyCode('s1');
      await channel.server.close();
      await pumpEventQueue();
      withPeer(alice).updateDraft('hors ligne');
      expect(withPeer(alice).sendMessage(), isTrue);
      await pumpEventQueue();

      final again = ScriptedChannel.after(channel);
      nextChannel = () => again;
      await connection.retryNow();
      // The relay kept the conversation with Alice, not the one with Bob.
      again.receive(const RegisteredFrame(id: me, sessions: ['s1']));
      await pumpEventQueue();

      expect(withPeer(alice).reconnecting, isFalse);
      expect(withPeer(alice).peerLeft, isFalse);
      expect(withPeer(bob).peerLeft, isTrue);
      final sent = await again.openedSent('s1');
      expect(sent.whereType<MessageCommitFrame>().map((f) => f.text), [
        'hors ligne',
      ]);
      // And the conversation goes on, with the same keys.
      await again.receiveSecure(
        const MessageCommitFrame(
          sid: 's1',
          seq: 1,
          text: 'te revoilà',
          mid: '0000000000000001',
        ),
      );
      await pumpEventQueue();
      expect((withPeer(alice).messages.last as ChatMessage).text, 'te revoilà');
    });

    test('not back in time: they end', () async {
      await channel.server.close();
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(connection.sessions.every((s) => s.peerLeft), isTrue);
      expect(connection.sessions.any((s) => s.reconnecting), isFalse);
    });

    test('the peer away, then back', () async {
      await receive(const PeerAwayFrame(sid: 's1'));
      expect(withPeer(alice).peerAway, isTrue);
      expect(withPeer(alice).peerLeft, isFalse);
      expect(withPeer(bob).reconnecting, isFalse);
      await receive(const PeerBackFrame(sid: 's1'));
      expect(withPeer(alice).reconnecting, isFalse);
    });

    test('a camera view stops while a connection is lost', () async {
      withPeer(alice).live.request();
      await receive(const PeerAwayFrame(sid: 's1'));
      expect(withPeer(alice).live.watch, LiveWatch.idle);
    });
  });

  test('a new ID closes every session', () async {
    await connection.regenerateId();
    expect(connection.sessions, isEmpty);
    expect(connection.active, isNull);
    expect(channel.sink.sent.whereType<SessionLeaveFrame>(), hasLength(2));
  });
}
