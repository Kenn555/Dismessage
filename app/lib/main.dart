import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'features/chat/overlay_panel.dart';
import 'features/home/home_screen.dart';
import 'features/legal/consent_gate.dart';
import 'services/background_mode.dart';
import 'services/connection_service.dart';
import 'services/contacts_service.dart';
import 'services/desktop_overlay.dart';
import 'services/identity_service.dart';
import 'services/legal_consent.dart';
import 'services/live_camera.dart';
import 'services/live_fullscreen.dart';
import 'services/live_video.dart';
import 'services/media_devices.dart';
import 'services/notifications/chat_notifications.dart';
import 'services/notifications/system_notifier.dart';
import 'services/page_lifecycle.dart';
import 'theme/app_theme.dart';
import 'widgets/live_view.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = PrefsStore(await SharedPreferences.getInstance());
  final settings = ServerSettings(store);
  final contacts = ContactsService(store);
  final devices = DevicePreferences(store);
  final connection = ConnectionService(
    identity: IdentityService(store),
    serverUri: settings.serverUri,
    acceptsRequestFrom: contacts.allowsRequestFrom,
    createLiveCamera: () => platformLiveCamera(deviceId: devices.cameraId),
  );
  // Known before the first camera request: it then leaves at once.
  platformLiveVideo().decoders().ignore();
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
  // The Windows overlay panel shows the conversation even when another app
  // has the focus.
  final overlay = DesktopOverlay(connection: connection);
  final initial = WidgetsBinding.instance.lifecycleState;
  var resumed = initial == null
      ? !(!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
      : initial == AppLifecycleState.resumed;
  void updateVisible() => notifications.appVisible = resumed || overlay.active;
  updateVisible();
  overlay.addListener(updateVisible);
  AppLifecycleListener(
    onStateChange: (state) {
      resumed = state == AppLifecycleState.resumed;
      updateVisible();
      // Minimized, or in the background: the user would no longer see that
      // their camera is on. Another window in front is not enough for that.
      if (state == AppLifecycleState.hidden ||
          state == AppLifecycleState.paused) {
        connection.stopSharedCameras();
      }
    },
  );
  final panel = overlay.supported ? overlay : null;
  runApp(
    DismessageApp(
      connection: connection,
      settings: settings,
      contacts: contacts,
      background: BackgroundMode(store),
      consent: consent,
      onConsent: startConnection,
      overlay: panel,
      fullscreen: LiveFullscreen(connection: connection, overlay: panel),
      devices: devices,
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
    required this.fullscreen,
    required this.devices,
    this.background,
    this.overlay,
  });

  final LegalConsent consent;

  /// Starts the connection once the terms are accepted.
  final VoidCallback onConsent;

  final ConnectionService connection;
  final ServerSettings settings;
  final ContactsService contacts;
  final BackgroundMode? background;

  /// The Windows overlay panel; null elsewhere.
  final DesktopOverlay? overlay;

  /// The peer's camera in full screen.
  final LiveFullscreen fullscreen;

  /// The camera and microphone chosen in the settings.
  final DevicePreferences devices;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dismessage',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      builder: (context, child) => LiveFullscreenHost(
        fullscreen: fullscreen,
        panel: (session) => OverlayPanel(
          key: ValueKey('fullscreen-${session.sid}'),
          session: session,
          contacts: contacts,
          inFullscreen: true,
          onExit: fullscreen.exit,
          onFullscreen: fullscreen.exit,
        ),
        child: overlay == null
            ? child!
            : DesktopOverlayHost(
                overlay: overlay!,
                contacts: contacts,
                fullscreen: fullscreen,
                child: child!,
              ),
      ),
      home: ConsentGate(
        consent: consent,
        onAccepted: onConsent,
        child: HomeScreen(
          connection: connection,
          settings: settings,
          contacts: contacts,
          background: background,
          overlay: overlay,
          fullscreen: fullscreen,
          devices: devices,
        ),
      ),
    );
  }
}
