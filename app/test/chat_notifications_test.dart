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
  NotifierCallbacks? callbacks;

  @override
  void listen(NotifierCallbacks callbacks) => this.callbacks = callbacks;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return true;
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
    channel.receive(const SessionStartedFrame(sid: 's1', peer: peer));
    await pumpEventQueue();
    session = connection.session!;
  });

  tearDown(() {
    notifications.dispose();
    connection.dispose();
  });

  Future<void> receive(RelayedFrame frame) async {
    channel.receive(frame);
    await pumpEventQueue();
  }

  Future<void> message(String text, {String mid = 'aaaabbbbccccdddd'}) =>
      receive(MessageCommitFrame(sid: 's1', seq: ++seq, text: text, mid: mid));

  Future<void> typing(String text) =>
      receive(DraftSnapshotFrame(sid: 's1', seq: ++seq, text: text));

  test('asks once for the right to notify', () {
    expect(notifier.permissionRequests, 1);
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
    channel.sink.sent.clear();

    notifier.callbacks!.onReply('s1', 'Oui, j’arrive');
    final commit = channel.sink.sent.whereType<MessageCommitFrame>().single;
    expect(commit.text, 'Oui, j’arrive');
    expect(session.messages.last, isA<ChatMessage>());
    expect((session.messages.last as ChatMessage).fromMe, isTrue);
    expect(notifier.cancelled, ['s1']);
    // The draft in progress is streamed again to the peer.
    final after = channel.sink.sent.skipWhile((f) => f is! MessageCommitFrame);
    expect(after.whereType<DraftOpsFrame>(), isNotEmpty);
  });

  test('a reply for an ended conversation only closes it', () async {
    notifier.callbacks!.onReply('old-session', 'Trop tard');
    expect(channel.sink.sent.whereType<MessageCommitFrame>(), isEmpty);
    expect(notifier.cancelled, ['old-session']);
  });

  test('without a saved contact, the title is the formatted ID', () async {
    await contacts.remove(peer);
    notifications.appVisible = false;
    await message('Coucou');
    expect(notifier.shown.single.title, '318 343 691');
  });
}
