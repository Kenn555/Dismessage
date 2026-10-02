import 'dart:async';

import 'package:dismessage/config.dart';
import 'package:dismessage/features/home/home_screen.dart';
import 'package:dismessage/services/connection_service.dart';
import 'package:dismessage/services/contacts_service.dart';
import 'package:dismessage/services/identity_service.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'fakes.dart';

const timeout = Duration(seconds: kConnectTimeoutSeconds);

void main() {
  late ConnectionService connection;

  Future<void> pumpHome(
    WidgetTester tester,
    WebSocketChannel Function() channel,
  ) async {
    final store = MemoryStore();
    connection = ConnectionService(
      identity: IdentityService(store),
      serverUri: Uri.parse('wss://far-away.example/ws'),
      connect: (_) => channel(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          connection: connection,
          settings: ServerSettings(store, fallback: connection.serverUri),
          contacts: ContactsService(store),
        ),
      ),
    );
    // Not awaited: start() waits for the handshake, which only times out
    // when the test advances the fake clock.
    unawaited(connection.start());
    await tester.pump();
  }

  Future<void> cleanUp(WidgetTester tester) async {
    connection.dispose();
    await tester.pumpWidget(const SizedBox());
    // Let an in-flight handshake timeout fire (it is a no-op once disposed).
    await tester.pump(timeout);
  }

  testWidgets('first attempt shows no banner', (tester) async {
    await pumpHome(tester, HangingChannel.new);
    expect(connection.status, ServerStatus.connecting);
    expect(find.byKey(const Key('connection-banner')), findsNothing);
    await cleanUp(tester);
  });

  testWidgets('a stuck handshake times out and explains why', (tester) async {
    await pumpHome(tester, HangingChannel.new);
    await tester.pump(timeout);
    await tester.pump();

    expect(connection.status, ServerStatus.offline);
    expect(connection.failures, 1);
    expect(find.byKey(const Key('connection-banner')), findsOneWidget);
    expect(find.text('Serveur injoignable (tentative 1)'), findsOneWidget);
    expect(find.textContaining('ne répond pas'), findsOneWidget);
    expect(find.text('Serveur : wss://far-away.example/ws'), findsOneWidget);
    expect(find.byKey(const Key('retry-now')), findsOneWidget);
    await cleanUp(tester);
  });

  testWidgets('retry is automatic, with a growing delay', (tester) async {
    var attempts = 0;
    await pumpHome(tester, () {
      attempts++;
      return HangingChannel();
    });
    await tester.pump(timeout); // attempt 1 fails
    expect(attempts, 1);
    await tester.pump(const Duration(seconds: 2)); // retry after 2 s
    expect(attempts, 2);
    expect(connection.status, ServerStatus.connecting);
    await tester.pump(timeout); // attempt 2 fails
    await tester.pump(const Duration(seconds: 3));
    expect(attempts, 2, reason: 'second delay is 4 s, not 2 s');
    await tester.pump(const Duration(seconds: 1));
    expect(attempts, 3);
    await cleanUp(tester);
  });

  testWidgets('"Réessayer" skips the wait', (tester) async {
    var attempts = 0;
    await pumpHome(tester, () {
      attempts++;
      return HangingChannel();
    });
    await tester.pump(timeout);
    await tester.tap(find.byKey(const Key('retry-now')));
    await tester.pump();
    expect(attempts, 2);
    expect(find.text('Connexion en cours… (tentative 2)'), findsOneWidget);
    await cleanUp(tester);
  });

  testWidgets('a server that never confirms registration is abandoned', (
    tester,
  ) async {
    await pumpHome(tester, ScriptedChannel.new);
    expect(connection.status, ServerStatus.connecting);
    await tester.pump(timeout);
    await tester.pump();
    expect(connection.status, ServerStatus.offline);
    expect(
      find.textContaining("pas confirmé l'enregistrement"),
      findsOneWidget,
    );
    await cleanUp(tester);
  });

  testWidgets('getting online clears the banner and the counter', (
    tester,
  ) async {
    late ScriptedChannel last;
    var first = true;
    await pumpHome(tester, () {
      if (first) {
        first = false;
        return HangingChannel();
      }
      return last = ScriptedChannel();
    });
    await tester.pump(timeout);
    await tester.pump(const Duration(seconds: 2));
    last.receive(RegisteredFrame(id: connection.myId!));
    await tester.pump();

    expect(connection.status, ServerStatus.online);
    expect(connection.failures, 0);
    expect(connection.lastError, isNull);
    expect(find.byKey(const Key('connection-banner')), findsNothing);
    await cleanUp(tester);
  });
}
