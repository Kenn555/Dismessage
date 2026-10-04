import 'package:dismessage/config.dart';
import 'package:dismessage/features/home/home_screen.dart';
import 'package:dismessage/services/background_mode.dart';
import 'package:dismessage/services/connection_service.dart';
import 'package:dismessage/services/contacts_service.dart';
import 'package:dismessage/services/identity_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  const channel = MethodChannel('dismessage/background');
  late MemoryStore store;
  late ConnectionService connection;
  late List<Object?> calls;

  setUp(() {
    store = MemoryStore()
      ..values[IdentityService.idKey] = '482913075'
      ..values[IdentityService.secretKey] = 'secret';
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add('${call.method}:${call.arguments}');
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> pumpHome(WidgetTester tester, BackgroundMode background) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    connection = ConnectionService(
      identity: IdentityService(store),
      serverUri: Uri.parse('ws://test/ws'),
      connect: (_) => ScriptedChannel(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          connection: connection,
          settings: ServerSettings(store, fallback: Uri.parse('ws://test/ws')),
          contacts: ContactsService(store),
          background: background,
        ),
      ),
    );
  }

  Future<void> cleanUp(WidgetTester tester) async {
    connection.dispose();
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('off by default; the switch saves it and starts the service', (
    tester,
  ) async {
    final background = BackgroundMode(store, supported: true);
    await pumpHome(tester, background);
    expect(background.enabled, isFalse);

    await tester.tap(find.byKey(const Key('settings')));
    await tester.pumpAndSettle();
    expect(find.text('Rester joignable en arrière-plan'), findsOneWidget);
    await tester.tap(find.byKey(const Key('background-switch')));
    await tester.pumpAndSettle();

    expect(background.enabled, isTrue);
    // Read by the boot receiver, as flutter.dismessage.background.
    expect(store.values[BackgroundMode.key], 'true');
    expect(calls, ['setEnabled:true']);

    await tester.tap(find.byKey(const Key('background-switch')));
    await tester.pumpAndSettle();
    expect(store.values[BackgroundMode.key], 'false');
    expect(calls.last, 'setEnabled:false');
    await cleanUp(tester);
  });

  testWidgets('no settings outside Android (web, Windows)', (tester) async {
    final background = BackgroundMode(store, supported: false);
    await pumpHome(tester, background);
    expect(find.byKey(const Key('settings')), findsNothing);
    await background.setEnabled(true);
    expect(background.enabled, isFalse);
    expect(calls, isEmpty);
    await cleanUp(tester);
  });
}
