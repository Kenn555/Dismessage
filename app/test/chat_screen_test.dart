import 'package:dismessage/config.dart';
import 'package:dismessage/features/chat/chat_screen.dart';
import 'package:dismessage/services/chat_session.dart';
import 'package:dismessage/services/connection_service.dart';
import 'package:dismessage/services/contacts_service.dart';
import 'package:dismessage/services/identity_service.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const peer = '318343691';

void main() {
  late MemoryStore store;
  late ContactsService contacts;
  late ChatSession session;
  late List<Frame> sent;

  Future<void> pumpChat(WidgetTester tester) async {
    store = MemoryStore();
    contacts = ContactsService(store);
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
          contacts: contacts,
        ),
      ),
    );
  }

  testWidgets('unknown peer: title is the ID, contact can be saved', (
    tester,
  ) async {
    await pumpChat(tester);
    expect(find.text('318 343 691'), findsOneWidget);

    await tester.tap(find.byKey(const Key('save-contact')));
    await tester.pumpAndSettle();
    expect(find.text('ID : 318 343 691'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('contact-name')), 'Bob');
    await tester.tap(find.byKey(const Key('contact-save')));
    await tester.pumpAndSettle();

    expect(contacts.byId(peer)?.name, 'Bob');
    expect(find.text('Bob'), findsOneWidget);
    // Known by name now: the ID in the header is masked.
    expect(find.text('318 *** 691 · En direct'), findsOneWidget);
    expect(find.text('Bob ajouté aux contacts.'), findsOneWidget);
  });

  testWidgets('saving a contact never stores the conversation', (tester) async {
    await pumpChat(tester);
    session.receive(
      const MessageCommitFrame(
        sid: 's1',
        seq: 1,
        text: 'secret du jour',
        mid: 'aaaabbbbccccdddd',
      ),
    );
    await tester.pump();
    await contacts.save(peer, 'Bob');
    expect(store.values.values.join(), isNot(contains('secret du jour')));
  });
}
