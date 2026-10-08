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
const peer = '318343691';

void main() {
  late ScriptedChannel channel;
  late ConnectionService connection;
  late ContactsService contacts;
  late MemoryStore store;

  Future<void> pumpHome(WidgetTester tester) async {
    // Tall surface so the contact list is on screen.
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    channel = ScriptedChannel();
    store = MemoryStore()
      ..values[IdentityService.idKey] = me
      ..values[IdentityService.secretKey] = 'secret';
    connection = ConnectionService(
      identity: IdentityService(store),
      serverUri: Uri.parse('ws://test/ws'),
      connect: (_) => channel,
      acceptsRequestFrom: (from) => contacts.allowsRequestFrom(from),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          connection: connection,
          settings: ServerSettings(store, fallback: Uri.parse('ws://test/ws')),
          contacts: contacts = ContactsService(store),
        ),
      ),
    );
    await connection.start();
    channel.receive(const RegisteredFrame(id: me));
    await tester.pump();
    expect(find.text('En ligne'), findsOneWidget);
  }

  Future<void> cleanUp(WidgetTester tester) async {
    connection.dispose();
    await tester.pumpWidget(const SizedBox());
  }

  Future<void> sendRequest(WidgetTester tester) async {
    await tester.enterText(find.byKey(const Key('peer-id')), '318 343 691');
    await tester.tap(find.byKey(const Key('connect')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('connecting shows a waiting card instead of the button', (
    tester,
  ) async {
    await pumpHome(tester);
    await sendRequest(tester);

    expect(channel.sink.sent.last, isA<ConnectRequestFrame>());
    expect(find.byKey(const Key('pending-request')), findsOneWidget);
    expect(find.text('Demande envoyée à 318 343 691'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(const Key('connect')), findsNothing);
    await cleanUp(tester);
  });

  testWidgets('cancel withdraws the request and restores the button', (
    tester,
  ) async {
    await pumpHome(tester);
    await sendRequest(tester);
    await tester.tap(find.byKey(const Key('cancel-request')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final cancel = channel.sink.sent.last as ConnectCancelFrame;
    expect(cancel.peer, peer);
    expect(find.byKey(const Key('pending-request')), findsNothing);
    expect(find.byKey(const Key('connect')), findsOneWidget);
    await cleanUp(tester);
  });

  testWidgets('a rejection ends the wait with a message', (tester) async {
    await pumpHome(tester);
    await sendRequest(tester);
    channel.receive(const ConnectRejectFrame(peer: peer));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('pending-request')), findsNothing);
    expect(find.text('318 343 691 a refusé la conversation.'), findsOneWidget);
    await cleanUp(tester);
  });

  testWidgets('an offline peer ends the wait with a message', (tester) async {
    await pumpHome(tester);
    await sendRequest(tester);
    channel.receive(const PeerOfflineFrame(peer: peer));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('pending-request')), findsNothing);
    expect(find.text('318 343 691 est hors ligne.'), findsOneWidget);
    await cleanUp(tester);
  });

  testWidgets('regenerating asks for confirmation, then the relay gives it', (
    tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(find.byKey(const Key('regenerate-id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(channel.sink.sent.last, isNot(isA<IdRequestFrame>()));

    await tester.tap(find.byKey(const Key('regenerate-id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Générer'));
    await tester.pump();
    expect(channel.sink.sent.last, isA<IdRequestFrame>());

    channel.receive(const IdAssignedFrame(id: '123456789', secret: 'new'));
    await tester.pump();
    final register = channel.sink.sent.last as RegisterFrame;
    expect(register.id, '123456789');
    channel.receive(const RegisteredFrame(id: '123456789'));
    await tester.pump();

    // The old ID is released only once the new one is registered.
    final release = channel.sink.sent.last as ReleaseFrame;
    expect(release.id, me);
    expect(connection.myId, '123456789');
    expect(find.text('123 *** 789'), findsOneWidget);
    final relay = Uri.parse('ws://test/ws');
    expect(
      IdentityService(store).load(relay)!.id,
      '123456789',
      reason: 'kept for this relay',
    );
    await cleanUp(tester);
  });

  testWidgets('no key from the peer: closed, nothing sent in clear', (
    tester,
  ) async {
    await pumpHome(tester);
    // The peer never sends its key (or the relay drops it).
    channel.receive(const SessionStartedFrame(sid: 's1', peer: peer));
    await tester.pump();
    final session = connection.sessions.single;
    session.updateDraft('Personne ne doit lire ça');
    await tester.pump(const Duration(seconds: kE2eHandshakeSeconds));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(connection.sessions, isEmpty);
    expect(channel.sink.sent.whereType<SessionLeaveFrame>().single.sid, 's1');
    expect(channel.sink.sent.whereType<SealedFrame>(), isEmpty);
    expect(
      find.text(
        'Chiffrement impossible avec 318 343 691 : '
        'conversation fermée, rien n’a été envoyé.',
      ),
      findsOneWidget,
    );
    await cleanUp(tester);
  });

  testWidgets('a request refused by the relay limit ends the wait', (
    tester,
  ) async {
    await pumpHome(tester);
    await sendRequest(tester);
    channel.receive(
      const ErrorFrame(
        code: ErrorCodes.rateLimited,
        message: 'Trop de tentatives, réessayez dans un instant.',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('pending-request')), findsNothing);
    expect(find.byKey(const Key('connect')), findsOneWidget);
    expect(
      find.text('Trop de tentatives, réessayez dans un instant.'),
      findsOneWidget,
    );
    expect(connection.status, ServerStatus.online);
    await cleanUp(tester);
  });

  testWidgets('the request expires without answer', (tester) async {
    await pumpHome(tester);
    await sendRequest(tester);
    await tester.pump(const Duration(seconds: kConnectRequestTimeoutSeconds));
    await tester.pump(const Duration(milliseconds: 300));

    expect(channel.sink.sent.last, isA<ConnectCancelFrame>());
    expect(find.byKey(const Key('pending-request')), findsNothing);
    expect(find.text("318 343 691 n'a pas répondu."), findsOneWidget);
    await cleanUp(tester);
  });

  testWidgets('incoming dialog closes when the requester cancels', (
    tester,
  ) async {
    await pumpHome(tester);
    channel.receive(const IncomingRequestFrame(from: peer));
    await tester.pumpAndSettle();
    expect(find.text('318 343 691 veut discuter avec vous.'), findsOneWidget);

    channel.receive(const ConnectCancelFrame(peer: peer));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('318 343 691 a annulé sa demande.'), findsOneWidget);
    // No answer is sent for a withdrawn request.
    expect(channel.sink.sent.whereType<ConnectRejectFrame>(), isEmpty);
    await cleanUp(tester);
  });

  testWidgets('accepting the incoming dialog sends connect_accept', (
    tester,
  ) async {
    await pumpHome(tester);
    channel.receive(const IncomingRequestFrame(from: peer));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accepter'));
    await tester.pumpAndSettle();
    expect((channel.sink.sent.last as ConnectAcceptFrame).from, peer);
    await cleanUp(tester);
  });

  testWidgets('answering from a notification closes the dialog', (
    tester,
  ) async {
    await pumpHome(tester);
    channel.receive(const IncomingRequestFrame(from: peer));
    await tester.pumpAndSettle();
    expect(find.text('Demande de conversation'), findsOneWidget);

    // As the notification's « Refuser » button does.
    connection.reject(peer);
    await tester.pumpAndSettle();
    expect(find.text('Demande de conversation'), findsNothing);
    expect(channel.sink.sent.whereType<ConnectRejectFrame>(), hasLength(1));
    await cleanUp(tester);
  });

  group('blocking', () {
    Future<void> openSettings(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('settings')));
      await tester.pumpAndSettle();
    }

    testWidgets('"Bloquer" refuses, blocks, and the next request is ignored', (
      tester,
    ) async {
      await pumpHome(tester);
      channel.receive(const IncomingRequestFrame(from: peer));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('request-block')));
      await tester.pumpAndSettle();

      expect((channel.sink.sent.last as ConnectRejectFrame).peer, peer);
      expect(contacts.isBlocked(peer), isTrue);
      expect(find.text('318 343 691 est bloqué.'), findsOneWidget);

      final sent = channel.sink.sent.length;
      channel.receive(const IncomingRequestFrame(from: peer));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      // No answer either: the requester cannot tell.
      expect(channel.sink.sent, hasLength(sent));
      await cleanUp(tester);
    });

    testWidgets('contacts only: a stranger is ignored, a contact is not', (
      tester,
    ) async {
      await pumpHome(tester);
      await openSettings(tester);
      await tester.tap(find.byKey(const Key('contacts-only-switch')));
      await tester.pumpAndSettle();
      expect(contacts.contactsOnly, isTrue);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      channel.receive(const IncomingRequestFrame(from: peer));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      await contacts.save(peer, 'Bob');
      channel.receive(const IncomingRequestFrame(from: peer));
      await tester.pumpAndSettle();
      expect(find.textContaining('Bob'), findsWidgets);
      expect(find.byType(AlertDialog), findsOneWidget);
      await cleanUp(tester);
    });

    testWidgets('a contact is blocked from its menu, unblocked in settings', (
      tester,
    ) async {
      await pumpHome(tester);
      await contacts.save(peer, 'Bob');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('contact-menu-$peer')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bloquer'));
      await tester.pumpAndSettle();
      expect(contacts.isBlocked(peer), isTrue);

      await openSettings(tester);
      expect(find.text('Bob'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('unblock-$peer')));
      await tester.pumpAndSettle();
      expect(contacts.isBlocked(peer), isFalse);
      expect(find.byKey(const Key('no-blocked')), findsOneWidget);
      await cleanUp(tester);
    });
  });

  group('contacts', () {
    testWidgets('empty list explains what contacts are for', (tester) async {
      await pumpHome(tester);
      expect(find.textContaining('Aucun contact'), findsOneWidget);
      await cleanUp(tester);
    });

    testWidgets('add a contact with a name, then call it in one tap', (
      tester,
    ) async {
      await pumpHome(tester);
      await tester.tap(find.byKey(const Key('add-contact')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('contact-name')), ' Bob ');
      await tester.enterText(
        find.byKey(const Key('contact-id')),
        '318 343 691',
      );
      await tester.tap(find.byKey(const Key('contact-save')));
      await tester.pumpAndSettle();

      expect(contacts.byId(peer)?.name, 'Bob');
      expect(find.text('Bob'), findsOneWidget);
      // A saved contact's ID is masked until revealed.
      expect(find.text('318 *** 691'), findsOneWidget);
      await tester.tap(find.byKey(const Key('reveal-contact-ids')));
      await tester.pump();
      expect(find.text('318 343 691'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('contact-$peer')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect((channel.sink.sent.last as ConnectRequestFrame).to, peer);
      expect(find.text('Demande envoyée à Bob'), findsOneWidget);
      await cleanUp(tester);
    });

    testWidgets('the dialog validates name and ID', (tester) async {
      await pumpHome(tester);
      await tester.tap(find.byKey(const Key('add-contact')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('contact-id')), '12');
      await tester.tap(find.byKey(const Key('contact-save')));
      await tester.pump();
      expect(find.text('Nom requis'), findsOneWidget);
      expect(find.text('ID invalide (9 chiffres)'), findsOneWidget);
      expect(contacts.contacts, isEmpty);
      await cleanUp(tester);
    });

    testWidgets('known contacts are named in requests and messages', (
      tester,
    ) async {
      await pumpHome(tester);
      await contacts.save(peer, 'Bob');
      channel.receive(const IncomingRequestFrame(from: peer));
      await tester.pumpAndSettle();
      expect(
        find.text('Bob (318 *** 691) veut discuter avec vous.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Refuser'));
      await tester.pumpAndSettle();

      channel.receive(const PeerOfflineFrame(peer: peer));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Bob est hors ligne.'), findsOneWidget);
      await cleanUp(tester);
    });

    testWidgets('rename and remove (with undo) from the menu', (tester) async {
      await pumpHome(tester);
      await contacts.save(peer, 'Bob');
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('contact-menu-$peer')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Renommer'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('contact-name')), 'Robert');
      await tester.tap(find.byKey(const Key('contact-save')));
      await tester.pumpAndSettle();
      expect(contacts.byId(peer)?.name, 'Robert');

      await tester.tap(find.byKey(const ValueKey('contact-menu-$peer')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Supprimer'));
      await tester.pumpAndSettle();
      expect(contacts.contacts, isEmpty);
      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();
      expect(contacts.byId(peer)?.name, 'Robert');
      await cleanUp(tester);
    });

    testWidgets('your own ID cannot be saved as a contact', (tester) async {
      await pumpHome(tester);
      await tester.tap(find.byKey(const Key('add-contact')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('contact-name')), 'Moi');
      await tester.enterText(find.byKey(const Key('contact-id')), me);
      await tester.tap(find.byKey(const Key('contact-save')));
      await tester.pumpAndSettle();
      expect(contacts.contacts, isEmpty);
      expect(find.text("C'est votre propre ID"), findsOneWidget);
      await cleanUp(tester);
    });
  });
}
