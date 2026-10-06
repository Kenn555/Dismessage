import 'package:dismessage/services/chat_session.dart';
import 'package:dismessage/services/connection_service.dart';
import 'package:dismessage/services/identity_service.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const me = '482913075';
const alice = '318343691';
const bob = '555666777';

void main() {
  late ScriptedChannel channel;
  late ConnectionService connection;

  setUp(() async {
    channel = ScriptedChannel();
    final store = MemoryStore()
      ..values[IdentityService.idKey] = me
      ..values[IdentityService.secretKey] = 'secret';
    connection = ConnectionService(
      identity: IdentityService(store),
      serverUri: Uri.parse('ws://test/ws'),
      connect: (_) => channel,
      reconnectDelay: const Duration(hours: 1),
    );
    await connection.start();
    channel.receive(const RegisteredFrame(id: me));
    channel.receive(const SessionStartedFrame(sid: 's1', peer: alice));
    channel.receive(const SessionStartedFrame(sid: 's2', peer: bob));
    await pumpEventQueue();
  });

  tearDown(() => connection.dispose());

  ChatSession withPeer(String peer) =>
      connection.sessions.singleWhere((s) => s.peer == peer);

  Future<void> receive(Frame frame) async {
    channel.receive(frame);
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

  test('losing the relay ends every session', () async {
    await channel.server.close();
    await pumpEventQueue();
    expect(connection.sessions.every((s) => s.peerLeft), isTrue);
  });

  test('a new ID closes every session', () async {
    await connection.regenerateId();
    expect(connection.sessions, isEmpty);
    expect(connection.active, isNull);
    expect(channel.sink.sent.whereType<SessionLeaveFrame>(), hasLength(2));
  });
}
