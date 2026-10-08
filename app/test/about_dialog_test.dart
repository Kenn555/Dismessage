import 'package:dismessage/config.dart';
import 'package:dismessage/features/home/home_screen.dart';
import 'package:dismessage/services/background_mode.dart';
import 'package:dismessage/services/connection_service.dart';
import 'package:dismessage/services/contacts_service.dart';
import 'package:dismessage/services/identity_service.dart';
import 'package:dismessage/theme/app_theme.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late ConnectionService connection;
  late List<Uri> opened;
  late ScriptedChannel channel;

  Future<void> pumpHome(
    WidgetTester tester, {
    Size size = const Size(1000, 1600),
    bool opens = true,
    bool backgroundSupported = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    opened = [];
    channel = ScriptedChannel();
    final store = MemoryStore()
      ..values[IdentityService.idKey] = '482913075'
      ..values[IdentityService.secretKey] = 'secret';
    connection = ConnectionService(
      identity: IdentityService(store),
      serverUri: Uri.parse('ws://test/ws'),
      connect: (_) => channel,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: HomeScreen(
          connection: connection,
          settings: ServerSettings(store, fallback: Uri.parse('ws://test/ws')),
          contacts: ContactsService(store),
          background: BackgroundMode(store, supported: backgroundSupported),
          openLink: (url) async {
            opened.add(url);
            return opens;
          },
        ),
      ),
    );
    await connection.start();
    channel.receive(const RegisteredFrame(id: '482913075'));
    await tester.pump();
  }

  Future<void> cleanUp(WidgetTester tester) async {
    connection.dispose();
    await tester.pumpWidget(const SizedBox());
  }

  Future<void> openAbout(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('about')));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the version and opens the GitHub page', (tester) async {
    await pumpHome(tester);
    await openAbout(tester);

    expect(find.byKey(const Key('about-dialog')), findsOneWidget);
    expect(find.text('Version $kAppVersion'), findsOneWidget);
    expect(find.text('github.com/Kenn555/Dismessage'), findsOneWidget);
    await tester.tap(find.byKey(const Key('about-github')));
    await tester.pump();
    expect(opened, [Uri.parse(kRepositoryUrl)]);
    await cleanUp(tester);
  });

  testWidgets('no browser: the link is copied instead', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpHome(tester, opens: false);
    await openAbout(tester);
    await tester.tap(find.byKey(const Key('about-github')));
    await tester.pump();
    await tester.pump();

    expect(copied, kRepositoryUrl);
    expect(
      find.text("Impossible d'ouvrir le navigateur : lien copié."),
      findsOneWidget,
    );
    await cleanUp(tester);
  });

  testWidgets('lists the licenses of the components', (tester) async {
    await pumpHome(tester);
    await openAbout(tester);
    await tester.tap(find.byKey(const Key('about-licenses')));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
    await cleanUp(tester);
  });

  testWidgets('on a small phone, the header buttons are in a menu', (
    tester,
  ) async {
    await pumpHome(
      tester,
      size: const Size(320, 640),
      backgroundSupported: true,
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('about')), findsNothing);
    await tester.tap(find.byKey(const Key('header-menu')));
    await tester.pumpAndSettle();
    expect(find.text('Réglages'), findsOneWidget);
    expect(find.text('Serveur'), findsOneWidget);
    await openAbout(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Version $kAppVersion'), findsOneWidget);
    await cleanUp(tester);
  });

  testWidgets('with room, they are separate icons', (tester) async {
    await pumpHome(
      tester,
      size: const Size(480, 800),
      backgroundSupported: true,
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('header-menu')), findsNothing);
    for (final key in ['settings', 'server-settings', 'about']) {
      expect(find.byKey(Key(key)), findsOneWidget);
    }
    await cleanUp(tester);
  });
}
