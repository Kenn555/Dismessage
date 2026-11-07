// The real Windows overlay panel, through the C++ runner (overlay.cpp):
//
//   cd app && flutter run -d windows -t tool/check_windows_overlay.dart
//
// Prints each check and exits (code 0 when all pass). Windows is queried
// directly (the window is left out of screenshots): position, translucency,
// clicks going through, the keyboard kept, the Ctrl+Alt+D shortcut. Two
// in-memory identities talk through an in-process relay: the user's own ID
// is never used. Keys are really typed: leave the mouse and keyboard alone
// while it runs.
import 'dart:io';

import 'package:dismessage/features/chat/overlay_panel.dart';
import 'package:dismessage/services/connection_service.dart';
import 'package:dismessage/services/contacts_service.dart';
import 'package:dismessage/services/desktop_overlay.dart';
import 'package:dismessage/services/identity_service.dart';
import 'package:dismessage/services/window_fullscreen.dart';
import 'package:dismessage/theme/app_theme.dart';
import 'package:dismessage_server/dismessage_server.dart';
import 'package:flutter/material.dart';

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

/// user32, from PowerShell.
const _user32 = r'''
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class W {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern bool GetLayeredWindowAttributes(IntPtr h, out uint k, out byte a, out uint f);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowDisplayAffinity(IntPtr h, out uint a);
  [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, out RECT r, uint c);
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint c, uint t);
  public static void Key(byte k, uint f) { keybd_event(k, (byte)MapVirtualKey(k, 0), f, UIntPtr.Zero); }
}
"@
''';

/// Runs [script] with `$h` = this app's window; returns its output lines.
Future<List<String>> _query(String script) async {
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-Command',
    '$_user32\n\$h = (Get-Process -Id $pid).MainWindowHandle\n$script',
  ]);
  return '${result.stdout}'
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
}

/// "left top right bottom|exstyle|alpha|foreground|hit" for the window.
Future<Map<String, String>> window() async {
  final lines = await _query(r'''
$r = New-Object W+RECT; [void][W]::GetWindowRect($h, [ref]$r)
"rect=$($r.L) $($r.T) $($r.R) $($r.B)"
"ex=$([W]::GetWindowLongPtr($h, -20).ToInt64())"
"style=$([W]::GetWindowLongPtr($h, -16).ToInt64())"
$k = 0; $a = 0; $f = 0
if ([W]::GetLayeredWindowAttributes($h, [ref]$k, [ref]$a, [ref]$f)) { "alpha=$a" } else { "alpha=" }
"foreground=$([W]::GetForegroundWindow() -eq $h)"
$d = 0; [void][W]::GetWindowDisplayAffinity($h, [ref]$d); "affinity=$d"
$p = New-Object W+POINT; $p.X = [int](($r.L + $r.R) / 2); $p.Y = [int](($r.T + $r.B) / 2)
"hit=$([W]::GetAncestor([W]::WindowFromPoint($p), 2) -eq $h)"
$w = New-Object W+RECT; [void][W]::SystemParametersInfo(0x30, 0, [ref]$w, 0)
"work=$($w.L) $($w.T) $($w.R) $($w.B)"
''');
  return {
    for (final line in lines)
      if (line.contains('='))
        line.substring(0, line.indexOf('=')): line.substring(
          line.indexOf('=') + 1,
        ),
  };
}

List<int> _ints(String? text) =>
    (text ?? '').split(' ').map(int.tryParse).whereType<int>().toList();

/// Presses Ctrl+Alt+D, as the user would (anywhere on the desktop).
Future<void> shortcut() => _query(r'''
[W]::Key(0x11, 0); [W]::Key(0x12, 0)
[W]::Key(0x44, 0); [W]::Key(0x44, 2)
[W]::Key(0x12, 2); [W]::Key(0x11, 2)
''');

/// Types [keys] (virtual-key codes of letters) into whatever has the focus.
Future<void> type(String letters) => _query(
  [
    for (final code in letters.toUpperCase().codeUnits)
      '[W]::Key($code, 0); '
          '[W]::Key($code, 2)',
  ].join('\n'),
);

const _layered = 0x80000, _transparent = 0x20, _topmost = 0x8;
const _caption = 0xC00000;

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
  final overlay = DesktopOverlay(connection: me);
  runApp(
    MaterialApp(
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      builder: (context, child) => DesktopOverlayHost(
        overlay: overlay,
        contacts: contacts,
        child: child!,
      ),
      home: const Scaffold(body: Center(child: Text('Vérification'))),
    ),
  );
  try {
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
    await Future<void>.delayed(const Duration(seconds: 1));

    final before = await window();
    check(
      before['ex']!.isNotEmpty &&
          int.parse(before['ex']!) & _transparent == 0 &&
          int.parse(before['style']!) & _caption != 0,
      'fenêtre normale au départ',
    );

    // From another app in front (the terminal), as the user would: the
    // shortcut lets Windows give the panel the foreground.
    await shortcut();
    await waitFor(() => overlay.active, 'shortcut enters');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    var w = await window();
    final rect = _ints(w['rect']), work = _ints(w['work']);
    final ex = int.parse(w['ex']!);
    check(
      ex & _layered != 0 && ex & _transparent != 0 && ex & _topmost != 0,
      'panneau translucide, au premier plan, transparent aux clics (ex=$ex)',
    );
    final width = work[2] - work[0];
    final scale =
        WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
    final height = (DesktopOverlay.panelHeight * scale).round();
    check(
      rect[3] - rect[1] == height,
      'deux lignes de haut ($height px : ${rect[3] - rect[1]})',
    );
    check(
      rect[1] == work[1] + (DesktopOverlay.panelMargin * scale).round() &&
          (rect[2] - rect[0] - width ~/ 3).abs() <= 2 &&
          ((rect[0] - work[0]) - (work[2] - rect[2])).abs() <= 2,
      'un tiers de l’écran, centré, sous le haut de l’écran (fenêtre ${w['rect']}, '
      'écran ${w['work']})',
    );
    check(int.parse(w['style']!) & _caption == 0, 'sans barre de titre');
    check(
      w['affinity'] == '${0x11}',
      'absent des captures d’écran (affinité ${w['affinity']})',
    );
    check(w['foreground'] == 'True', 'le panneau a le clavier');
    check(w['hit'] == 'False', 'un clic au centre atteint la fenêtre derrière');
    // Never type into another app.
    if (w['foreground'] != 'True') throw StateError('panel not in front');
    await type('salut');
    await waitFor(
      () => peer.sessions.single.remoteDraft == 'salut',
      'typed in the panel (${peer.sessions.single.remoteDraft})',
    );
    check(true, 'la frappe dans le panneau part en direct');

    peer.sessions.single.updateDraft('Un très long message qui continue ' * 6);
    await Future<void>.delayed(const Duration(seconds: 2));
    w = await window();
    final grown = _ints(w['rect']);
    check(
      grown[3] - grown[1] > height,
      'un long texte agrandit le panneau (${grown[3] - grown[1]} px)',
    );
    peer.sessions.single.updateDraft('Court');
    await Future<void>.delayed(const Duration(seconds: 1));
    w = await window();
    final shrunk = _ints(w['rect']);
    check(
      shrunk[3] - shrunk[1] == height,
      'puis il revient à deux lignes (${shrunk[3] - shrunk[1]} px)',
    );

    await shortcut();
    await waitFor(() => !overlay.active, 'shortcut leaves');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    w = await window();
    check(
      int.parse(w['ex']!) & (_transparent | _topmost) == 0 &&
          int.parse(w['style']!) & _caption != 0 &&
          w['rect'] == before['rect'],
      'Ctrl+Alt+D : la fenêtre normale revient à sa place (${w['rect']})',
    );

    check(
      me.sessions.single.localDraft == 'salut',
      'ce qui a été tapé reste dans le brouillon de la conversation',
    );

    // The header button: the window is already in front.
    await overlay.enter(me.sessions.single);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    w = await window();
    check(
      int.parse(w['ex']!) & _transparent != 0 && w['foreground'] == 'True',
      'le bouton de l’en-tête ouvre le panneau, avec le clavier',
    );

    // What is typed always arrives, entering again and again, from the
    // normal window as from another app having had the keyboard.
    final draft = me.sessions.single;
    var typed = draft.localDraft;
    var arrived = 0;
    for (var round = 0; round < 8; round++) {
      await overlay.exit();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (round.isEven) {
        await overlay.enter(draft);
      } else {
        await shortcut();
        await waitFor(() => overlay.active, 'shortcut enters');
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
      w = await window();
      if (w['foreground'] != 'True') throw StateError('panel not in front');
      await type('a');
      typed += 'a';
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (draft.localDraft == typed) arrived++;
      typed = draft.localDraft;
    }
    check(arrived == 8, 'la frappe arrive à chaque entrée ($arrived sur 8)');

    // The camera on the left: clicks reach it, and only it.
    await overlay.setLiveView(const Size(85, 64));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    w = await window();
    final box = _ints(w['rect']);
    final hover = await _query('''
[void][System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")
[System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(${box[0] + 20}, ${box[1] + 20})
Start-Sleep -Milliseconds 200
"over=\$(([W]::GetWindowLongPtr(\$h, -20).ToInt64() -band 0x20) -eq 0)"
[System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(${box[0] + 300}, ${box[1] + 20})
Start-Sleep -Milliseconds 200
"beside=\$(([W]::GetWindowLongPtr(\$h, -20).ToInt64() -band 0x20) -ne 0)"
''');
    check(
      hover.contains('over=True'),
      'souris sur la caméra : les clics atteignent le bandeau',
    );
    check(
      hover.contains('beside=True'),
      'souris à côté : les clics traversent toujours',
    );
    await overlay.setLiveView(null);

    // Full screen, and back to the panel's window.
    await overlay.exit();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final normal = await window();
    await platformSetFullscreen(true);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    w = await window();
    final full = _ints(w['rect']);
    final screenLines = await _query(r'''
[void][System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")
$s = [System.Windows.Forms.Screen]::FromHandle($h).Bounds
"$($s.Left) $($s.Top) $($s.Right) $($s.Bottom)"
''');
    check(
      w['rect'] == screenLines.first,
      'plein écran : la fenêtre couvre l’écran (${w['rect']}, écran '
      '${screenLines.first}, ${full.length} valeurs)',
    );
    check(
      int.parse(w['affinity']!) == 0x11,
      'plein écran : toujours absent des captures',
    );
    await platformSetFullscreen(false);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    w = await window();
    check(w['rect'] == normal['rect'], 'la fenêtre revient à sa place');

    await overlay.exit();
  } catch (e) {
    check(false, 'exception : $e');
  } finally {
    overlay.dispose();
    me.dispose();
    peer.dispose();
    await server.close(force: true);
  }
  stdout.writeln(_failures == 0 ? 'TOUT EST BON' : '$_failures ÉCHEC(S)');
  exit(_failures == 0 ? 0 : 1);
}
