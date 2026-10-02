import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'features/home/home_screen.dart';
import 'services/connection_service.dart';
import 'services/contacts_service.dart';
import 'services/identity_service.dart';

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
    const seed = Color(0xFF5B5BD6);
    return MaterialApp(
      title: 'Dismessage',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: seed,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: HomeScreen(
        connection: connection,
        settings: settings,
        contacts: contacts,
      ),
    );
  }
}
