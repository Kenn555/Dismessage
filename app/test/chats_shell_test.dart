import 'package:dismessage/config.dart';
import 'package:dismessage/features/chat/chat_screen.dart';
import 'package:dismessage/features/home/home_screen.dart';
import 'package:dismessage/services/connection_service.dart';
import 'package:dismessage/services/contacts_service.dart';
import 'package:dismessage/services/identity_service.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const me = '482913075';
const alice = '318343691';
const bob = '555666777';

void main() {
  late ScriptedChannel channel;
  late ConnectionService connection;
  late ContactsService contacts;

  Future<void> pumpHome(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    channel = ScriptedChannel();
    final store = MemoryStore()
      ..values[IdentityService.idKey] = me
      ..values[IdentityService.secretKey] = 'secret';
    connection = ConnectionService(
      identity: IdentityService(store),
      serverUri: Uri.parse('ws://test/ws'),
      connect: (_) => channel,
    );
    contacts = ContactsService(store);
    await contacts.save(alice, 'Alice');
    await contacts.save(bob, 'Bob');
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          connection: connection,
          settings: ServerSettings(store, fallback: Uri.parse('ws://test/ws')),
          contacts: contacts,
          buildChat: (session, {required active}) => ChatScreen(
            session: session,
            connection: connection,
            contacts: contacts,
            active: active,
            cameraAvailable: false,
            createCamera: () => null,
            createRecorder: FakeVoiceRecorder.new,
            createAudioBackend: FakeAudioBackend.new,
          ),
        ),
      ),
    );
    await connection.start();
    channel.receive(const RegisteredFrame(id: me));
    await tester.pump();
  }

  Future<void> cleanUp(WidgetTester tester) async {
    connection.dispose();
    await tester.pumpWidget(const SizedBox());
  }

  Future<void> start(WidgetTester tester, String sid, String peer) async {
    await channel.startSession(sid, peer);
    await tester.pumpAndSettle();
  }

  Future<void> message(WidgetTester tester, String sid, String text) async {
    await channel.receiveSecure(
      MessageCommitFrame(sid: sid, seq: 1, text: text, mid: 'aaaabbbbccccdddd'),
    );
    await tester.pumpAndSettle();
  }

  /// The chat screen of the conversation [sid].
  Finder chatOf(String sid) => find.byKey(ValueKey(sid));

  const phone = Size(600, 1000);
  const desktop = Size(1280, 900);

  testWidgets('the chat menu shows the safety code of the peer', (
    tester,
  ) async {
    await pumpHome(tester, phone);
    await start(tester, 's1', alice);
    final code = await channel.peerSafetyCode('s1');
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('verify-encryption')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('encryption-dialog')), findsOneWidget);
    expect(code, isNotNull);
    expect(find.text(code!), findsOneWidget);
    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();
    await cleanUp(tester);
  });

  group('narrow screen', () {
    testWidgets('floating avatars from two conversations', (tester) async {
      await pumpHome(tester, phone);
      await start(tester, 's1', alice);
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byKey(const Key('chats-rail')), findsNothing);

      await start(tester, 's2', bob);
      expect(find.byKey(const Key('chats-rail')), findsOneWidget);
      expect(find.byKey(const ValueKey('rail-$alice')), findsOneWidget);
      expect(find.byKey(const ValueKey('rail-$bob')), findsOneWidget);
      expect(find.byKey(const ValueKey('rail-presence-$alice-on')), findsOne);
      expect(find.byKey(const Key('chats-sidebar')), findsNothing);
      await cleanUp(tester);
    });

    testWidgets('unread badge, tap switches, long press closes', (
      tester,
    ) async {
      await pumpHome(tester, phone);
      await start(tester, 's1', alice);
      await start(tester, 's2', bob);
      await message(tester, 's1', 'Coucou');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('unread-$alice')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('rail-$alice')));
      await tester.pumpAndSettle();
      expect(connection.active?.sid, 's1');
      expect(find.byKey(const ValueKey('unread-$alice')), findsNothing);

      await tester.longPress(find.byKey(const ValueKey('rail-$bob')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('rail-close')));
      await tester.pumpAndSettle();
      expect(channel.sink.sent.whereType<SessionLeaveFrame>().single.sid, 's2');
      expect(find.byKey(const Key('chats-rail')), findsNothing);
      expect(find.byType(ChatScreen), findsOneWidget);
      await cleanUp(tester);
    });

    testWidgets('what is typed stays when switching', (tester) async {
      await pumpHome(tester, phone);
      await start(tester, 's1', alice);
      await start(tester, 's2', bob);
      await tester.tap(find.byKey(const ValueKey('rail-$alice')));
      await tester.pumpAndSettle();
      final aliceInput = find.descendant(
        of: chatOf('s1'),
        matching: find.byKey(const Key('chat-input')),
      );
      await tester.enterText(aliceInput, 'Brouillon');
      await tester.pump(const Duration(milliseconds: kDraftBatchMs * 2));

      await tester.tap(find.byKey(const ValueKey('rail-$bob')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rail-$alice')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(aliceInput).controller!.text,
        'Brouillon',
      );
      expect(tester.widget<TextField>(aliceInput).focusNode!.hasFocus, isTrue);
      await cleanUp(tester);
    });

    testWidgets('back keeps the conversations, listed on the home screen', (
      tester,
    ) async {
      await pumpHome(tester, phone);
      await start(tester, 's1', alice);
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(ChatScreen), findsNothing);
      expect(channel.sink.sent.whereType<SessionLeaveFrame>(), isEmpty);
      expect(connection.active, isNull);
      expect(find.byKey(const Key('open-sessions')), findsOneWidget);

      await message(tester, 's1', 'Tu es parti ?');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('session-unread-$alice')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('open-sessions')),
          matching: find.byKey(const ValueKey('session-$alice')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.text('Tu es parti ?'), findsOneWidget);
      expect(connection.sessions.single.unread, 0);
      await cleanUp(tester);
    });

    testWidgets('a contact already in conversation is reopened', (
      tester,
    ) async {
      await pumpHome(tester, phone);
      await start(tester, 's1', alice);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const ValueKey('contact-$alice')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('contact-$alice')));
      await tester.pumpAndSettle();
      expect(channel.sink.sent.whereType<ConnectRequestFrame>(), isEmpty);
      expect(find.byType(ChatScreen), findsOneWidget);
      await cleanUp(tester);
    });

    testWidgets('leaving the last conversation goes back home', (tester) async {
      await pumpHome(tester, phone);
      await start(tester, 's1', alice);
      await tester.tap(find.byKey(const Key('close-session')));
      await tester.pumpAndSettle();
      expect(channel.sink.sent.whereType<SessionLeaveFrame>().single.sid, 's1');
      expect(find.byType(ChatScreen), findsNothing);
      expect(find.byKey(const Key('open-sessions')), findsNothing);
      expect(find.byKey(const Key('my-id')), findsOneWidget);
      await cleanUp(tester);
    });
  });

  group('wide screen', () {
    testWidgets('a sidebar lists the conversations', (tester) async {
      await pumpHome(tester, desktop);
      await start(tester, 's1', alice);
      expect(find.byKey(const Key('chats-sidebar')), findsOneWidget);
      expect(find.byKey(const Key('chats-rail')), findsNothing);

      await start(tester, 's2', bob);
      await message(tester, 's1', 'Coucou');
      final sidebar = find.byKey(const Key('chats-sidebar'));
      Finder inSidebar(Finder f) => find.descendant(of: sidebar, matching: f);
      expect(inSidebar(find.text('Alice')), findsOneWidget);
      expect(inSidebar(find.text('Bob')), findsOneWidget);
      expect(
        inSidebar(find.byKey(const ValueKey('session-presence-$alice-on'))),
        findsOneWidget,
      );
      expect(
        inSidebar(find.byKey(const ValueKey('session-unread-$alice'))),
        findsOneWidget,
      );

      channel.receive(const PeerLeftFrame(sid: 's1'));
      await tester.pumpAndSettle();
      expect(
        inSidebar(find.byKey(const ValueKey('session-presence-$alice-off'))),
        findsOneWidget,
      );
      expect(inSidebar(find.text('Déconnecté')), findsOneWidget);

      await tester.tap(
        inSidebar(find.byKey(const ValueKey('session-close-$alice'))),
      );
      await tester.pumpAndSettle();
      expect(inSidebar(find.text('Alice')), findsNothing);
      expect(connection.sessions.single.peer, bob);
      await cleanUp(tester);
    });

    testWidgets('"new conversation" goes home, conversations kept', (
      tester,
    ) async {
      await pumpHome(tester, desktop);
      await start(tester, 's1', alice);
      await tester.tap(find.byKey(const Key('sidebar-new')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chats-sidebar')), findsNothing);
      expect(find.byKey(const Key('open-sessions')), findsOneWidget);
      expect(connection.sessions, hasLength(1));
      await cleanUp(tester);
    });
  });
}
