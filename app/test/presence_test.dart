import 'package:dismessage/config.dart';
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

  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    channel = ScriptedChannel();
    final store = MemoryStore()
      ..values[IdentityService.idKey] = me
      ..values[IdentityService.secretKey] = 'secret';
    contacts = ContactsService(store);
    await contacts.save(alice, 'Alice');
    connection = ConnectionService(
      identity: IdentityService(store),
      serverUri: Uri.parse('ws://test/ws'),
      connect: (_) => channel,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          connection: connection,
          settings: ServerSettings(store, fallback: Uri.parse('ws://test/ws')),
          contacts: contacts,
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

  String status(WidgetTester tester, String id) =>
      tester.widget<Text>(find.byKey(ValueKey('contact-status-$id'))).data!;

  testWidgets('contacts are watched once registered', (tester) async {
    await pumpHome(tester);
    final watch = channel.sink.sent.whereType<PresenceWatchFrame>().last;
    expect(watch.ids, [alice]);
    // Unknown until the server answers: no dot, no status.
    expect(find.byKey(const ValueKey('presence-$alice-on')), findsNothing);
    expect(find.byKey(const ValueKey('presence-$alice-off')), findsNothing);
    expect(status(tester, alice), '318 343 691');
    await cleanUp(tester);
  });

  testWidgets('a green dot shows who is online, grey otherwise', (
    tester,
  ) async {
    await pumpHome(tester);
    channel.receive(const PresenceFrame(id: alice, online: true));
    await tester.pump();
    expect(find.byKey(const ValueKey('presence-$alice-on')), findsOneWidget);
    expect(status(tester, alice), '318 343 691 · En ligne');

    channel.receive(const PresenceFrame(id: alice, online: false));
    await tester.pump();
    expect(find.byKey(const ValueKey('presence-$alice-off')), findsOneWidget);
    expect(status(tester, alice), '318 343 691 · Hors ligne');
    await cleanUp(tester);
  });

  testWidgets('a new contact is added to the watch list', (tester) async {
    await pumpHome(tester);
    await contacts.save(bob, 'Bob');
    await tester.pump();
    final watch = channel.sink.sent.whereType<PresenceWatchFrame>().last;
    expect(watch.ids.toSet(), {alice, bob});
    await cleanUp(tester);
  });

  testWidgets('presence of strangers is ignored', (tester) async {
    await pumpHome(tester);
    channel.receive(const PresenceFrame(id: bob, online: true));
    await tester.pump();
    expect(connection.isOnline(bob), isNull);
    await cleanUp(tester);
  });

  testWidgets('leaving the page disconnects, coming back reconnects', (
    tester,
  ) async {
    await pumpHome(tester);
    channel.receive(const PresenceFrame(id: alice, online: true));
    await tester.pump();

    connection.suspend();
    await tester.pump();
    expect(connection.status, ServerStatus.offline);
    expect(connection.isOnline(alice), isNull);
    // No automatic reconnection while the page is away.
    await tester.pump(const Duration(seconds: kMaxReconnectDelaySeconds + 1));
    expect(connection.status, ServerStatus.offline);

    final again = ScriptedChannel();
    channel = again;
    await connection.resume();
    expect(again.sink.sent.whereType<RegisterFrame>(), hasLength(1));
    again.receive(const RegisteredFrame(id: me));
    await tester.pump();
    expect(connection.status, ServerStatus.online);
    expect(again.sink.sent.whereType<PresenceWatchFrame>().single.ids, [alice]);
    await cleanUp(tester);
  });

  testWidgets('presence is forgotten when the relay connection drops', (
    tester,
  ) async {
    await pumpHome(tester);
    channel.receive(const PresenceFrame(id: alice, online: true));
    await tester.pump();
    expect(connection.isOnline(alice), isTrue);

    await channel.server.close();
    await tester.pump();
    expect(connection.isOnline(alice), isNull);
    expect(find.byKey(const ValueKey('presence-$alice-on')), findsNothing);
    await cleanUp(tester);
  });
}
