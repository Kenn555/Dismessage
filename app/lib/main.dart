import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'features/home/home_screen.dart';
import 'features/legal/consent_gate.dart';
import 'services/background_mode.dart';
import 'services/connection_service.dart';
import 'services/contacts_service.dart';
import 'services/identity_service.dart';
import 'services/legal_consent.dart';
import 'services/notifications/chat_notifications.dart';
import 'services/notifications/system_notifier.dart';
import 'services/page_lifecycle.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = PrefsStore(await SharedPreferences.getInstance());
  final settings = ServerSettings(store);
  final contacts = ContactsService(store);
  final connection = ConnectionService(
    identity: IdentityService(store),
    serverUri: settings.serverUri,
    acceptsRequestFrom: contacts.allowsRequestFrom,
  );
  // No connection to the relay (no ID, no IP seen) before the user is of age
  // and has accepted the terms.
  final consent = LegalConsent(store);
  void startConnection() {
    connection.start();
    watchPageLifecycle(
      onLeave: connection.suspend,
      onReturn: connection.resume,
    );
  }

  if (consent.accepted) startConnection();
  final notifications = ChatNotifications(
    connection: connection,
    contacts: contacts,
    notifier: platformNotifier(),
  );
  // Notify only what the user cannot see: app in the background, minimized,
  // another window or tab in front. On Android the app may have been
  // started at boot with no screen (background mode): hidden until resumed.
  final initial = WidgetsBinding.instance.lifecycleState;
  notifications.appVisible = initial == null
      ? !(!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
      : initial == AppLifecycleState.resumed;
  AppLifecycleListener(
    onStateChange: (state) =>
        notifications.appVisible = state == AppLifecycleState.resumed,
  );
  runApp(
    DismessageApp(
      connection: connection,
      settings: settings,
      contacts: contacts,
      background: BackgroundMode(store),
      consent: consent,
      onConsent: startConnection,
    ),
  );
}

class DismessageApp extends StatelessWidget {
  const DismessageApp({
    super.key,
    required this.connection,
    required this.settings,
    required this.contacts,
    required this.consent,
    required this.onConsent,
    this.background,
  });

  final LegalConsent consent;

  /// Starts the connection once the terms are accepted.
  final VoidCallback onConsent;

  final ConnectionService connection;
  final ServerSettings settings;
  final ContactsService contacts;
  final BackgroundMode? background;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dismessage',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: ConsentGate(
        consent: consent,
        onAccepted: onConsent,
        child: HomeScreen(
          connection: connection,
          settings: settings,
          contacts: contacts,
          background: background,
        ),
      ),
    );
  }
}
