import 'dart:convert';

import 'package:dismessage/services/chat_session.dart';
import 'package:dismessage/services/connection_service.dart';
import 'package:dismessage/services/contacts_service.dart';
import 'package:dismessage/services/identity_service.dart';
import 'package:dismessage/services/notifications/chat_notifications.dart';
import 'package:dismessage/services/notifications/system_notifier.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const me = '482913075';
const peer = '318343691';

class FakeNotifier implements SystemNotifier {
  final shown = <ChatNotice>[];
  final cancelled = <String>[];
  int permissionRequests = 0;

  /// Answer to the permission request (false: started with no screen).
  bool grant = true;
  NotifierCallbacks? callbacks;

  @override
  void listen(NotifierCallbacks callbacks) => this.callbacks = callbacks;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return grant;
  }

  @override
  bool get supportsReply => true;

  @override
  Future<void> show(ChatNotice notice) async => shown.add(notice);

  @override
  Future<void> cancel(String tag) async => cancelled.add(tag);
}

void main() {
  late ScriptedChannel channel;
  late ConnectionService connection;
  late ContactsService contacts;
  late FakeNotifier notifier;
  late ChatNotifications notifications;
  late ChatSession session;
  var seq = 0;

  setUp(() async {
    seq = 0;
    channel = ScriptedChannel();
    final store = MemoryStore()
      ..values[IdentityService.idKey] = me
      ..values[IdentityService.secretKey] = 'secret';
    contacts = ContactsService(store);
    await contacts.save(peer, 'Alice');
    connection = ConnectionService(
      identity: IdentityService(store),
      serverUri: Uri.parse('ws://test/ws'),
      connect: (_) => channel,
    );
    notifier = FakeNotifier();
    notifications = ChatNotifications(
      connection: connection,
      contacts: contacts,
      notifier: notifier,
      typingDelay: const Duration(milliseconds: 80),
    );
    await connection.start();
    channel.receive(const RegisteredFrame(id: me));
    await channel.startSession('s1', peer);
    await pumpEventQueue();
    session = connection.sessions.single;
  });

  tearDown(() {
    notifications.dispose();
    connection.dispose();
  });

  Future<void> receive(RelayedFrame frame) async {
    await channel.receiveSecure(frame);
    await pumpEventQueue();
  }

  Future<void> message(String text, {String mid = 'aaaabbbbccccdddd'}) =>
      receive(MessageCommitFrame(sid: 's1', seq: ++seq, text: text, mid: mid));

  Future<void> typing(String text) =>
      receive(DraftSnapshotFrame(sid: 's1', seq: ++seq, text: text));

  test('asks once for the right to notify', () {
    expect(notifier.permissionRequests, 1);
    notifications.appVisible = false;
    notifications.appVisible = true;
    expect(notifier.permissionRequests, 1, reason: 'already granted');
  });

  test('refused with no screen (boot), asked again when shown', () async {
    final hidden = FakeNotifier()..grant = false;
    final other = ChatNotifications(
      connection: connection,
      contacts: contacts,
      notifier: hidden,
    );
    addTearDown(other.dispose);
    other.appVisible = false;
    await pumpEventQueue();
    expect(hidden.permissionRequests, 1);
    hidden.grant = true;
    other.appVisible = true;
    await pumpEventQueue();
    expect(hidden.permissionRequests, 2);
  });

  test('nothing is notified while the conversation is visible', () async {
    await message('Coucou');
    await typing('Tu es là');
    expect(notifier.shown, isEmpty);
  });

  test('a hidden message is notified, with sound and reply', () async {
    notifications.appVisible = false;
    await message('Coucou');
    final notice = notifier.shown.single;
    expect(notice.tag, 's1');
    expect(notice.title, 'Alice');
    expect(notice.lines, ['Coucou']);
    expect(notice.alert, isTrue);
    expect(notice.canReply, isTrue);
  });

  test('unread messages pile up, the latest ones only', () async {
    notifications.appVisible = false;
    for (var i = 1; i <= kNotificationMaxLines + 2; i++) {
      await message('m$i', mid: i.toRadixString(16).padLeft(16, '0'));
    }
    final lines = notifier.shown.last.lines;
    expect(lines, hasLength(kNotificationMaxLines));
    expect(lines.last, 'm${kNotificationMaxLines + 2}');
    expect(lines.first, 'm3');
  });

  test('images and voice messages have a short label', () async {
    notifications.appVisible = false;
    await receive(
      VoiceFrame(
        sid: 's1',
        mid: '1111222233334444',
        durationMs: 2000,
        mime: 'audio/mp4',
        data: base64Encode([1, 2, 3]),
      ),
    );
    expect(notifier.shown.last.lines, ['🎤 Message vocal']);
  });

  test('typing is announced once, then updated silently', () async {
    notifications.appVisible = false;
    await typing('Sal');
    final first = notifier.shown.single;
    expect(first.title, 'Alice est en train d’écrire…');
    expect(first.lines, ['✍️ Sal']);
    expect(first.alert, isTrue);

    // Within the delay: no flood of updates…
    await typing('Salu');
    await typing('Salut');
    expect(notifier.shown, hasLength(1));
    // …then one silent update with the latest text.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final update = notifier.shown.last;
    expect(update.lines, ['✍️ Salut']);
    expect(update.alert, isFalse);
  });

  test('erasing everything removes the typing notification', () async {
    notifications.appVisible = false;
    await typing('Hmm');
    await receive(DraftClearFrame(sid: 's1', seq: ++seq));
    expect(notifier.cancelled, ['s1']);
  });

  test('the sent message replaces the typing line, with sound', () async {
    notifications.appVisible = false;
    await typing('Salut');
    await message('Salut !');
    final notice = notifier.shown.last;
    expect(notice.title, 'Alice');
    expect(notice.lines, ['Salut !']);
    expect(notice.alert, isTrue);
  });

  test('coming back clears the notification and stops notifying', () async {
    notifications.appVisible = false;
    await message('Coucou');
    notifications.appVisible = true;
    expect(notifier.cancelled, ['s1']);
    await message('Encore', mid: '0000000000000002');
    expect(notifier.shown, hasLength(1));
  });

  test('a reply from the notification is sent and clears it', () async {
    notifications.appVisible = false;
    await message('Tu viens ?');
    // A draft is in progress in the chat input.
    session.updateDraft('Je vé');
    await Future<void>.delayed(const Duration(milliseconds: kDraftBatchMs * 2));
    final before = (await channel.openedSent('s1')).length;

    notifier.callbacks!.onReply('s1', 'Oui, j’arrive');
    await pumpEventQueue();
    final sent = (await channel.openedSent('s1')).skip(before);
    final commit = sent.whereType<MessageCommitFrame>().single;
    expect(commit.text, 'Oui, j’arrive');
    expect(session.messages.last, isA<ChatMessage>());
    expect((session.messages.last as ChatMessage).fromMe, isTrue);
    expect(notifier.cancelled, ['s1']);
    // The draft in progress is streamed again to the peer.
    final after = sent.skipWhile((f) => f is! MessageCommitFrame);
    expect(after.whereType<DraftOpsFrame>(), isNotEmpty);
  });

  test('a reply for an ended conversation only closes it', () async {
    notifier.callbacks!.onReply('old-session', 'Trop tard');
    await pumpEventQueue();
    expect(channel.sink.sent.whereType<SealedFrame>(), isEmpty);
    expect(notifier.cancelled, ['old-session']);
  });

  test('without a saved contact, the title is the formatted ID', () async {
    await contacts.remove(peer);
    notifications.appVisible = false;
    await message('Coucou');
    expect(notifier.shown.single.title, '318 343 691');
  });

  group('requests', () {
    const stranger = '555666777';

    Future<void> request(String from) async {
      channel.receive(IncomingRequestFrame(from: from));
      await pumpEventQueue();
    }

    test('a hidden request is notified with Accept / Refuse', () async {
      notifications.appVisible = false;
      await request(stranger);
      final notice = notifier.shown.single;
      expect(notice.tag, 'request-$stranger');
      expect(notice.title, 'Demande de conversation');
      // An unknown person: the full ID, to know who it is.
      expect(notice.lines, ['555 666 777 veut discuter avec vous.']);
      expect(notice.alert, isTrue);
      expect(notice.actions.map((a) => (a.id, a.label, a.foreground)), [
        ('accept', 'Accepter', true),
        ('reject', 'Refuser', false),
      ]);
    });

    test('a saved contact is named', () async {
      notifications.appVisible = false;
      await request(peer);
      expect(notifier.shown.single.lines, ['Alice veut discuter avec vous.']);
    });

    test('nothing while the app is visible (the dialog shows)', () async {
      await request(stranger);
      expect(notifier.shown, isEmpty);
    });

    test('accepting from the notification answers and removes it', () async {
      notifications.appVisible = false;
      await request(stranger);
      notifier.callbacks!.onAction('request-$stranger', 'accept');
      await pumpEventQueue();
      expect(
        channel.sink.sent.whereType<ConnectAcceptFrame>().single.from,
        stranger,
      );
      expect(notifier.cancelled, ['request-$stranger']);
    });

    test('refusing from the notification answers and removes it', () async {
      notifications.appVisible = false;
      await request(stranger);
      notifier.callbacks!.onAction('request-$stranger', 'reject');
      await pumpEventQueue();
      expect(
        channel.sink.sent.whereType<ConnectRejectFrame>().single.peer,
        stranger,
      );
      expect(notifier.cancelled, ['request-$stranger']);
    });

    test('a withdrawn request is removed', () async {
      notifications.appVisible = false;
      await request(stranger);
      channel.receive(const ConnectCancelFrame(peer: stranger));
      await pumpEventQueue();
      expect(notifier.cancelled, ['request-$stranger']);
    });

    test('coming back to the app removes it (the dialog takes over)', () async {
      notifications.appVisible = false;
      await request(stranger);
      notifications.appVisible = true;
      expect(notifier.cancelled, contains('request-$stranger'));
    });
  });

  group('several conversations', () {
    const bob = '555666777';

    setUp(() async {
      await channel.startSession('s2', bob);
      await pumpEventQueue();
    });

    test('one notification per conversation', () async {
      notifications.appVisible = false;
      await message('Coucou');
      await receive(
        const MessageCommitFrame(
          sid: 's2',
          seq: 1,
          text: 'Salut',
          mid: '1111222233334444',
        ),
      );
      expect(notifier.shown.map((n) => n.tag), ['s1', 's2']);
      expect(notifier.shown.last.title, '555 666 777');
      expect(notifier.shown.last.lines, ['Salut']);
    });

    test('a reply goes to its own conversation', () async {
      notifications.appVisible = false;
      await message('Coucou');
      notifier.callbacks!.onReply('s1', 'Oui');
      await pumpEventQueue();
      final commit = (await channel.openedSent(
        's1',
      )).whereType<MessageCommitFrame>().single;
      expect(commit.sid, 's1');
      expect(commit.text, 'Oui');
      expect(connection.sessions.last.messages, isEmpty);
    });

    test('tapping a notification shows its conversation', () async {
      notifications.appVisible = false;
      expect(connection.active?.sid, 's2');
      await message('Coucou');
      notifier.callbacks!.onOpen('s1');
      expect(connection.active, session);
      expect(session.unread, 0);
    });

    test('closing a conversation removes its notification', () async {
      notifications.appVisible = false;
      await message('Coucou');
      connection.closeSession(session);
      expect(notifier.cancelled, contains('s1'));
    });
  });
}
