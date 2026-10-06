// Real Windows toasts, through the C++ runner (notifications.cpp):
//
//   cd app && flutter run -d windows -t tool/check_windows_notifications.dart
//
// Prints each check and exits (code 0 when all pass). Two in-memory
// identities talk through an in-process relay: the user's own ID is never
// used. Not a `flutter test`: the integration_test package would pull an
// Android Gradle plugin missing from the offline cache.
import 'dart:io';

import 'package:dismessage/services/connection_service.dart';
import 'package:dismessage/services/contacts_service.dart';
import 'package:dismessage/services/identity_service.dart';
import 'package:dismessage/services/notifications/chat_notifications.dart';
import 'package:dismessage/services/notifications/system_notifier.dart';
import 'package:dismessage_server/dismessage_server.dart';
import 'package:flutter/widgets.dart';

var _failures = 0;

void check(bool ok, String what) {
  stdout.writeln('${ok ? 'OK   ' : 'ÉCHEC'} $what');
  if (!ok) _failures++;
}

Future<void> waitFor(bool Function() condition, String reason) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Timed out: $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<String> _powershell(String script) async {
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-Command',
    "\$null = [Windows.UI.Notifications.ToastNotificationManager, "
        "Windows.UI.Notifications, ContentType = WindowsRuntime]\n$script",
  ]);
  return '${result.stdout}';
}

/// Dismessage's toasts as Windows keeps them: "tag|reply|buttons" per line,
/// telling whether the toast has a reply field and buttons. (Windows does not give back
/// the bound title and body: those are checked by chat_notifications_test.)
Future<List<String>> toastHistory() async => (await _powershell(r'''
$h = [Windows.UI.Notifications.ToastNotificationManager]::History.GetHistory('Dismessage.Desktop')
foreach ($t in $h) { $x = $t.Content.GetXml(); $t.Tag + '|' + ($x -match 'input id="reply"') + '|' + ($x -match 'arguments="button:') }
''')).split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

Future<void> clearToasts() => _powershell(
  "[Windows.UI.Notifications.ToastNotificationManager]::History"
  ".Clear('Dismessage.Desktop')",
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final server = await serve(
    Relay(IdStore.memory()),
    address: 'localhost',
    port: 0,
  );
  final uri = Uri.parse('ws://localhost:${server.port}/ws');
  final me = ConnectionService(
    identity: IdentityService(MemoryStore()),
    serverUri: uri,
  );
  final peer = ConnectionService(
    identity: IdentityService(MemoryStore()),
    serverUri: uri,
  );
  final contacts = ContactsService(MemoryStore());
  final notifications = ChatNotifications(
    connection: me,
    contacts: contacts,
    notifier: platformNotifier(),
    typingDelay: const Duration(milliseconds: 200),
  );
  try {
    await clearToasts();
    await me.start();
    await peer.start();
    await waitFor(
      () =>
          me.status == ServerStatus.online &&
          peer.status == ServerStatus.online,
      'both online',
    );
    await contacts.save(peer.myId!, 'Test Dismessage');
    final sub = peer.events.listen((e) {
      if (e is IncomingRequestEvent) peer.accept(e.from);
    });
    me.requestChat(peer.myId!);
    await waitFor(() => me.sessions.isNotEmpty, 'session');
    await sub.cancel();
    final sid = me.sessions.single.sid;

    // The app is not visible: notify.
    notifications.appVisible = false;

    peer.sessions.single.updateDraft('Salut, tu');
    await waitFor(() => me.sessions.single.remoteDraft == 'Salut, tu', 'draft');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    var history = await toastHistory();
    check(
      history.join() == '$sid|True|False',
      'la frappe est annoncée, avec un champ de réponse ($history)',
    );

    peer.sessions.single.updateDraft('Salut, tu es là ?');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    history = await toastHistory();
    check(
      history.join() == '$sid|True|False',
      'mise à jour sur place : toujours un seul toast ($history)',
    );

    peer.sessions.single.sendMessage();
    await waitFor(() => me.sessions.single.messages.isNotEmpty, 'message');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    history = await toastHistory();
    check(history.join() == '$sid|True|False', 'le message remplace la frappe');

    notifications.appVisible = true;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    history = await toastHistory();
    check(history.isEmpty, 'revenir dans l’appli retire le toast ($history)');

    // The click itself cannot be simulated: Windows has no API to type in
    // a toast. The channel → Dart path is the same as for a real click.
    notifications.appVisible = false;
    notifications.onReply(sid, 'Oui !');
    await waitFor(() => peer.sessions.single.messages.length == 1, 'reply');
    check(true, 'la réponse depuis le toast est envoyée');

    // A request while the app is hidden: a toast with Accept / Refuse.
    await clearToasts();
    final requester = ConnectionService(
      identity: IdentityService(MemoryStore()),
      serverUri: uri,
    );
    try {
      await requester.start();
      await waitFor(
        () => requester.status == ServerStatus.online,
        'requester online',
      );
      requester.requestChat(me.myId!);
      final tag = 'request-${requester.myId}';
      await Future<void>.delayed(const Duration(milliseconds: 600));
      history = await toastHistory();
      check(
        history.join() == '$tag|False|True',
        'une demande est notifiée avec « Accepter » / « Refuser » ($history)',
      );
      requester.cancelRequest();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      history = await toastHistory();
      check(history.isEmpty, 'une demande retirée disparaît ($history)');
    } finally {
      requester.dispose();
    }
  } catch (e) {
    check(false, 'exception : $e');
  } finally {
    notifications.dispose();
    me.dispose();
    peer.dispose();
    await server.close(force: true);
  }
  stdout.writeln(_failures == 0 ? 'TOUT EST BON' : '$_failures ÉCHEC(S)');
  exit(_failures == 0 ? 0 : 1);
}
