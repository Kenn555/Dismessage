import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'features/home/home_screen.dart';
import 'services/connection_service.dart';
import 'services/contacts_service.dart';
import 'services/identity_service.dart';
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
  runApp(
    DismessageApp(
      connection: connection,
      settings: settings,
      contacts: contacts,
    ),
  );
}

class DismessageApp extends StatelessWidget {
  const DismessageApp({
    super.key,
    required this.connection,
    required this.settings,
    required this.contacts,
  });

  final ConnectionService connection;
  final ServerSettings settings;
  final ContactsService contacts;

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
      ),
    );
  }
}
