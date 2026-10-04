import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'features/home/home_screen.dart';
import 'services/background_mode.dart';
import 'services/connection_service.dart';
import 'services/contacts_service.dart';
import 'services/identity_service.dart';
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
  );
  connection.start();
  watchPageLifecycle(onLeave: connection.suspend, onReturn: connection.resume);
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
    ),
  );
}

class DismessageApp extends StatelessWidget {
  const DismessageApp({
    super.key,
    required this.connection,
    required this.settings,
    required this.contacts,
    this.background,
  });

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
      home: HomeScreen(
        connection: connection,
        settings: settings,
        contacts: contacts,
        background: background,
      ),
    );
  }
}
