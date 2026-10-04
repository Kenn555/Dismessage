import 'package:dismessage/config.dart';
import 'package:dismessage/features/home/home_screen.dart';
import 'package:dismessage/services/connection_service.dart';
import 'package:dismessage/services/contacts_service.dart';
import 'package:dismessage/services/identity_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A channel whose connection always fails: the app stays offline.
class UnreachableChannel implements WebSocketChannel {
  @override
  Future<void> get ready => Future.error(WebSocketChannelException('offline'));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late MemoryStore store;
  late ConnectionService connection;
  late ServerSettings settings;

  Future<void> pumpHome(WidgetTester tester) async {
    settings = ServerSettings(
      store,
      fallback: Uri.parse('ws://unreachable/ws'),
    );
    connection = ConnectionService(
      identity: IdentityService(store),
      serverUri: settings.serverUri,
      connect: (_) => UnreachableChannel(),
      reconnectDelay: const Duration(hours: 1),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          connection: connection,
          settings: settings,
          contacts: ContactsService(store),
        ),
      ),
    );
    await connection.start();
    await tester.pump();
  }

  Future<void> cleanUp(WidgetTester tester) async {
    connection.dispose();
    await tester.pumpWidget(const SizedBox());
  }

  setUp(() {
    store = MemoryStore()
      ..values[IdentityService.idKey] = '482913075'
      ..values[IdentityService.secretKey] = 'secret';
  });

  testWidgets('shows the stored ID masked, revealed on demand', (
    tester,
  ) async {
    await pumpHome(tester);
    expect(find.text('482 *** 075'), findsOneWidget);
    expect(find.text('482 913 075'), findsNothing);
    expect(find.text('Hors ligne'), findsOneWidget);

    await tester.tap(find.byKey(const Key('reveal-my-id')));
    await tester.pump();
    expect(find.text('482 913 075'), findsOneWidget);
    await tester.tap(find.byKey(const Key('reveal-my-id')));
    await tester.pump();
    expect(find.text('482 *** 075'), findsOneWidget);
    await cleanUp(tester);
  });

  testWidgets('rejects an invalid peer ID', (tester) async {
    await pumpHome(tester);
    await tester.enterText(find.byKey(const Key('peer-id')), '12 34');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text('ID invalide (9 chiffres)'), findsOneWidget);
    await cleanUp(tester);
  });

  testWidgets('refuses to connect to your own ID', (tester) async {
    await pumpHome(tester);
    await tester.enterText(find.byKey(const Key('peer-id')), '482 913 075');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text("C'est votre propre ID"), findsOneWidget);
    await cleanUp(tester);
  });

  testWidgets('regenerating asks for confirmation then changes the ID', (
    tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(find.byKey(const Key('regenerate-id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(find.text('482 *** 075'), findsOneWidget);

    await tester.tap(find.byKey(const Key('regenerate-id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Générer'));
    await tester.pumpAndSettle();
    expect(find.text('482 *** 075'), findsNothing);
    expect(store.values[IdentityService.idKey], isNot('482913075'));
    expect(connection.myId, store.values[IdentityService.idKey]);
    await cleanUp(tester);
  });

  testWidgets('pasting a tunnel link changes and remembers the server', (
    tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(find.byKey(const Key('server-settings')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('server-address')),
      'pas une adresse',
    );
    await tester.tap(find.byKey(const Key('server-save')));
    await tester.pump();
    expect(find.text('Adresse invalide'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('server-address')),
      'https://abc-8080.euw.devtunnels.ms/',
    );
    await tester.tap(find.byKey(const Key('server-save')));
    await tester.pumpAndSettle();

    final expected = Uri.parse('wss://abc-8080.euw.devtunnels.ms/ws');
    expect(connection.serverUri, expected);
    expect(settings.serverUri, expected);
    expect(ServerSettings(store).serverUri, expected, reason: 'persisted');
    await cleanUp(tester);
  });
}
