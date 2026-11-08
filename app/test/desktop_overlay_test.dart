import 'package:dismessage/config.dart';
import 'package:dismessage/features/chat/chat_screen.dart';
import 'package:dismessage/features/chat/overlay_panel.dart';
import 'package:dismessage/features/home/home_screen.dart';
import 'package:dismessage/services/chat_session.dart';
import 'package:dismessage/services/connection_service.dart';
import 'package:dismessage/services/contacts_service.dart';
import 'package:dismessage/services/desktop_overlay.dart';
import 'package:dismessage/services/identity_service.dart';
import 'package:dismessage/services/image_codec.dart';
import 'package:dismessage/services/live_fullscreen.dart';
import 'package:dismessage/services/live_link.dart';
import 'package:dismessage/services/live_video.dart';
import 'package:dismessage/widgets/live_view.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'fakes.dart';

const me = '482913075';
const alice = '318343691';
const bob = '555666777';

void main() {
  late ScriptedChannel channel;
  late ConnectionService connection;
  late ContactsService contacts;
  late DesktopOverlay overlay;
  late List<String> native;
  Object? enterArgs;
  late List<double> resized;
  late FakeClipboardImages clipboard;
  late FakeLiveCamera camera;
  late LiveFullscreen fullscreen;
  late List<bool> system;
  const overlayChannel = MethodChannel('test/overlay');

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    native = [];
    resized = [];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      overlayChannel,
      (call) async {
        if (call.method == 'resize') {
          resized.add((call.arguments as Map)['height'] as double);
        } else {
          native.add(call.method);
        }
        if (call.method == 'enter') enterArgs = call.arguments;
        return null;
      },
    );
    channel = ScriptedChannel();
    clipboard = FakeClipboardImages();
    camera = FakeLiveCamera();
    final store = MemoryStore()
      ..values[IdentityService.idKey] = me
      ..values[IdentityService.secretKey] = 'secret';
    connection = ConnectionService(
      identity: IdentityService(store),
      serverUri: Uri.parse('ws://test/ws'),
      connect: (_) => channel,
      createLiveCamera: () => camera,
      decodeLiveFrame: (_) async => null,
      liveVideo: const NoLiveVideo(),
    );
    overlay = DesktopOverlay(
      connection: connection,
      channel: overlayChannel,
      supported: true,
      sendsFrames: false,
    );
    system = [];
    fullscreen = LiveFullscreen(
      connection: connection,
      overlay: overlay,
      setSystem: (on) async => system.add(on),
    );
    contacts = ContactsService(store);
    await contacts.save(alice, 'Alice');
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => LiveFullscreenHost(
          fullscreen: fullscreen,
          child: DesktopOverlayHost(
            overlay: overlay,
            contacts: contacts,
            fullscreen: fullscreen,
            clipboardImages: clipboard,
            encodeImage: (bytes) async => EncodedImage(
              bytes: bytes,
              width: 4,
              height: 3,
              // A real picture: the bubble behind the panel decodes it.
              preview: Uint8List.fromList(
                img.encodeJpg(img.Image(width: 4, height: 3)),
              ),
            ),
            child: child!,
          ),
        ),
        home: HomeScreen(
          connection: connection,
          settings: ServerSettings(store, fallback: Uri.parse('ws://test/ws')),
          contacts: contacts,
          overlay: overlay,
          fullscreen: fullscreen,
          buildChat: (session, {required active}) => ChatScreen(
            session: session,
            connection: connection,
            contacts: contacts,
            overlay: overlay,
            fullscreen: fullscreen,
            active: active,
            cameraAvailable: false,
            createCamera: () => null,
            createRecorder: FakeVoiceRecorder.new,
            createAudioBackend: FakeAudioBackend.new,
          ),
        ),
      ),
    );
    await connection.start();
    channel.receive(const RegisteredFrame(id: me));
    await tester.pump();
  }

  Future<void> cleanUp(WidgetTester tester) async {
    fullscreen.dispose();
    overlay.dispose();
    connection.dispose();
    await tester.pumpWidget(const SizedBox());
  }

  Future<void> start(WidgetTester tester, String sid, String peer) async {
    await channel.startSession(sid, peer);
    await tester.pumpAndSettle();
  }

  /// The shortcut, as the runner reports it.
  Future<void> hotkey(WidgetTester tester) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      overlayChannel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('hotkey')),
      (_) {},
    );
    await tester.pump();
  }

  /// Lets the peer's text roll out, and the panel report its height.
  Future<void> rollOut(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  final panel = find.byKey(const Key('overlay-panel'));
  final chatInput = find.byKey(const Key('chat-input'));

  testWidgets('the header button turns the window into the panel', (
    tester,
  ) async {
    await pumpApp(tester);
    await start(tester, 's1', alice);
    await channel.receiveSecure(
      const MessageCommitFrame(
        sid: 's1',
        seq: 1,
        text: 'Tu regardes le match ?',
        mid: 'aaaabbbbccccdddd',
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('enter-overlay')));
    await tester.pump();
    expect(native, ['enter']);
    expect(panel, findsOneWidget);
    // The rest of the app is kept, hidden.
    expect(chatInput, findsNothing);
    // Two lines: the window is sized for them.
    expect(enterArgs, {
      'height': DesktopOverlay.panelHeight,
      'margin': DesktopOverlay.panelMargin,
    });
    expect(resized, isEmpty);
    expect(
      tester.getSize(find.byKey(const Key('overlay-input'))).height,
      lessThanOrEqualTo(DesktopOverlay.panelLineHeight),
    );
    // The peer is not typing: their last bubble.
    expect(find.text('Tu regardes le match ?'), findsOneWidget);

    // Their typing, live; their last bubble moves up, dimmed.
    await channel.receiveSecure(
      const DraftSnapshotFrame(sid: 's1', seq: 2, text: 'Oui, et toi'),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('overlay-peer')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('overlay-previous'))).data,
      'Tu regardes le match ?',
    );

    // A long draft wraps: the window grows, up to panelMaxLines lines.
    await channel.receiveSecure(
      DraftSnapshotFrame(sid: 's1', seq: 3, text: 'Oui, et toi ' * 12),
    );
    await rollOut(tester);
    final grown = resized.last;
    expect(grown, greaterThan(DesktopOverlay.panelHeight + 10));
    await channel.receiveSecure(
      DraftSnapshotFrame(sid: 's1', seq: 4, text: 'Oui, et toi ' * 400),
    );
    await rollOut(tester);
    const line = DesktopOverlay.panelLineHeight;
    expect(
      resized.last,
      lessThanOrEqualTo(
        DesktopOverlay.panelHeight + line * (DesktopOverlay.panelMaxLines - 1),
      ),
    );
    expect(resized.last, greaterThan(grown));

    // My long typing too; then back to two lines.
    await tester.enterText(
      find.byKey(const Key('overlay-input')),
      'Je réponds longuement ' * 30,
    );
    await tester.pump();
    final both = resized.last;
    expect(both, greaterThan(resized[resized.length - 2]));
    await channel.receiveSecure(
      const DraftSnapshotFrame(sid: 's1', seq: 5, text: 'Ok'),
    );
    await tester.enterText(find.byKey(const Key('overlay-input')), 'Bien');
    await rollOut(tester);
    // Two lines, plus the peer's previous message above.
    expect(
      resized.last,
      DesktopOverlay.panelHeight + DesktopOverlay.panelLineHeight - 6,
    );

    await cleanUp(tester);
  });

  testWidgets('a window lower than the text asks again for its height', (
    tester,
  ) async {
    await pumpApp(tester);
    await start(tester, 's1', alice);
    for (final (seq, text) in [(1, 'Tu regardes le match ?'), (2, 'Oui')]) {
      await channel.receiveSecure(
        MessageCommitFrame(
          sid: 's1',
          seq: seq,
          text: text,
          mid: 'aaaabbbbccccdd0$seq',
        ),
      );
    }
    await tester.pump();
    await tester.tap(find.byKey(const Key('enter-overlay')));
    await rollOut(tester);
    // Two lines from the peer and mine: more than the two-line window.
    final needed = resized.single;
    expect(needed, greaterThan(DesktopOverlay.panelHeight));

    // The window ends up at two lines anyway (a late frame from before
    // the resize): my line would be cut, so the panel asks again.
    tester.view.physicalSize = const Size(640, DesktopOverlay.panelHeight);
    await tester.pump();
    await tester.pump();
    expect(resized, [needed, needed]);
    // Only once for that height, not at every frame.
    await rollOut(tester);
    expect(resized, [needed, needed]);

    await cleanUp(tester);
  });

  testWidgets('only the peer’s two latest messages show', (tester) async {
    await pumpApp(tester);
    await start(tester, 's1', alice);
    Future<void> receive(int seq, String text) => channel.receiveSecure(
      MessageCommitFrame(
        sid: 's1',
        seq: seq,
        text: text,
        mid: 'aaaabbbbcccc000$seq',
      ),
    );
    await receive(1, 'Premier');
    await receive(2, 'Deuxième');
    await tester.tap(find.byKey(const Key('enter-overlay')));
    await tester.pump();

    String? text(String key) => tester.widget<Text>(find.byKey(Key(key))).data;
    expect(text('overlay-previous'), 'Premier');
    expect(text('overlay-last'), 'Deuxième');

    await receive(3, 'Troisième');
    await tester.pump();
    expect(text('overlay-previous'), 'Deuxième');
    expect(text('overlay-last'), 'Troisième');
    expect(find.text('Premier'), findsNothing);

    // Typing again: the message in progress and the last one.
    await channel.receiveSecure(
      const DraftSnapshotFrame(sid: 's1', seq: 4, text: 'Et'),
    );
    await rollOut(tester);
    expect(text('overlay-previous'), 'Troisième');
    expect(find.byKey(const Key('overlay-peer')), findsOneWidget);
    expect(find.text('Deuxième'), findsNothing);

    await cleanUp(tester);
  });

  testWidgets('typing in the panel streams live, Enter sends, Escape leaves', (
    tester,
  ) async {
    await pumpApp(tester);
    await start(tester, 's1', alice);
    await tester.enterText(chatInput, 'Déjà ');
    await tester.tap(find.byKey(const Key('enter-overlay')));
    await tester.pump();

    final input = find.byKey(const Key('overlay-input'));
    // What was being typed carries over.
    expect(tester.widget<EditableText>(input).controller.text, 'Déjà ');
    await tester.enterText(input, 'Déjà vu');
    await tester.pump(const Duration(milliseconds: kDraftBatchMs * 2));
    var opened = await channel.openedSent('s1');
    final ops = opened.whereType<DraftOpsFrame>().expand((f) => f.ops);
    final snapshots = opened.whereType<DraftSnapshotFrame>();
    expect(
      TextDiff.applyAll(snapshots.isEmpty ? '' : snapshots.last.text, ops),
      'Déjà vu',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    opened = await channel.openedSent('s1');
    expect(opened.whereType<MessageCommitFrame>().single.text, 'Déjà vu');
    expect(tester.widget<EditableText>(input).controller.text, isEmpty);

    // Typed again, then back to the window: the input shows it.
    await tester.enterText(input, 'Suite');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(native, ['enter', 'exit']);
    expect(panel, findsNothing);
    expect(tester.widget<TextField>(chatInput).controller!.text, 'Suite');
    expect(find.text('Déjà vu'), findsOneWidget);

    await cleanUp(tester);
  });

  testWidgets('the shortcut enters with the conversation on screen, then '
      'leaves', (tester) async {
    await pumpApp(tester);
    await start(tester, 's1', alice);
    await start(tester, 's2', bob);
    connection.activate(connection.sessions.first);
    await tester.pump();

    await hotkey(tester);
    expect(native, ['enter']);
    expect(overlay.session?.peer, alice);
    expect(find.text('Alice'), findsOneWidget);

    await hotkey(tester);
    expect(native, ['enter', 'exit']);
    expect(panel, findsNothing);

    await cleanUp(tester);
  });

  testWidgets('without a conversation the shortcut does nothing', (
    tester,
  ) async {
    await pumpApp(tester);
    await hotkey(tester);
    expect(native, isEmpty);
    expect(panel, findsNothing);
    await cleanUp(tester);
  });

  testWidgets('the panel closes with its conversation', (tester) async {
    await pumpApp(tester);
    await start(tester, 's1', alice);
    await hotkey(tester);
    expect(panel, findsOneWidget);

    connection.closeSession(connection.sessions.single);
    await tester.pumpAndSettle();
    expect(native, ['enter', 'exit']);
    expect(panel, findsNothing);

    await cleanUp(tester);
  });

  testWidgets('a departed peer is shown, typing is off', (tester) async {
    await pumpApp(tester);
    await start(tester, 's1', alice);
    await hotkey(tester);
    channel.receive(const PeerLeftFrame(sid: 's1'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Déconnecté'), findsOneWidget);
    expect(
      tester
          .widget<EditableText>(find.byKey(const Key('overlay-input')))
          .readOnly,
      isTrue,
    );
    await cleanUp(tester);
  });

  group('the keyboard', () {
    FocusNode? primary() => FocusManager.instance.primaryFocus;

    Future<void> enter(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('enter-overlay')));
      await tester.pump();
      await tester.pump();
    }

    bool inPanel() {
      final context = primary()?.context;
      return context != null &&
          context.findAncestorWidgetOfExactType<OverlayPanel>() != null;
    }

    testWidgets('goes to the panel when the chat input had it', (tester) async {
      await pumpApp(tester);
      await start(tester, 's1', alice);
      await tester.tap(chatInput);
      await tester.pump();
      await enter(tester);
      expect(inPanel(), isTrue);
      await cleanUp(tester);
    });

    testWidgets('goes to the panel when another field had it', (tester) async {
      await pumpApp(tester);
      await start(tester, 's1', alice);
      // The shortcut, while the keyboard was on a button of the app.
      await tester.tap(find.byKey(const Key('save-contact')));
      await tester.pumpAndSettle();
      await hotkey(tester);
      await tester.pump();
      await tester.pump();
      expect(overlay.active, isTrue);
      expect(inPanel(), isTrue);
      await cleanUp(tester);
    });

    testWidgets('comes back to the panel if it was lost', (tester) async {
      await pumpApp(tester);
      await start(tester, 's1', alice);
      await enter(tester);
      primary()?.unfocus();
      await tester.pump();
      await tester.pump();
      expect(inPanel(), isTrue);
      await cleanUp(tester);
    });
  });

  group('pasting in the panel', () {
    Future<void> ctrl(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump();
    }

    Future<void> openPanel(WidgetTester tester) async {
      await start(tester, 's1', alice);
      await tester.tap(find.byKey(const Key('enter-overlay')));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a picture asks first, then Enter sends it', (tester) async {
      await pumpApp(tester);
      await openPanel(tester);
      clipboard.images = [
        Uint8List.fromList(img.encodeJpg(img.Image(width: 4, height: 3))),
      ];

      await ctrl(tester, LogicalKeyboardKey.keyV);
      expect(find.byKey(const Key('overlay-paste')), findsOneWidget);
      expect(find.textContaining('1 image'), findsOneWidget);
      expect(find.textContaining('Entrée : envoyer'), findsOneWidget);
      expect(connection.sessions.single.messages, isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('overlay-paste')), findsNothing);
      expect(connection.sessions.single.messages.single, isA<ChatImage>());
      // Still in the panel.
      expect(panel, findsOneWidget);
      await cleanUp(tester);
    });

    testWidgets('Escape cancels the paste, not the panel', (tester) async {
      await pumpApp(tester);
      await openPanel(tester);
      final file = FakeChosenFile('rapport.pdf', Uint8List(2048));
      clipboard.files = [file];

      await ctrl(tester, LogicalKeyboardKey.keyV);
      expect(find.textContaining('1 fichier (2 Ko)'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const Key('overlay-paste')), findsNothing);
      expect(panel, findsOneWidget);
      expect(connection.sessions.single.messages, isEmpty);
      expect(file.closed, isTrue);
      await cleanUp(tester);
    });

    testWidgets('any file can be pasted and sent', (tester) async {
      await pumpApp(tester);
      await openPanel(tester);
      clipboard.files = [
        FakeChosenFile('rapport.pdf', Uint8List(10)),
        FakeChosenFile('archive.zip', Uint8List(20)),
      ];
      await ctrl(tester, LogicalKeyboardKey.keyV);
      expect(find.textContaining('2 fichiers'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      final entries = connection.sessions.single.messages;
      expect(entries.whereType<ChatFile>(), hasLength(2));
      expect(entries.first.group, isNotNull);
      await cleanUp(tester);
    });

    testWidgets('text is simply pasted into the line', (tester) async {
      await pumpApp(tester);
      await openPanel(tester);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async =>
            call.method == 'Clipboard.getData' ? {'text': 'copié'} : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await ctrl(tester, LogicalKeyboardKey.keyV);
      await tester.pump();
      expect(connection.sessions.single.localDraft, 'copié');
      await cleanUp(tester);
    });

    testWidgets('files from the peer are answered once, with Ctrl+N or Ctrl+O', (
      tester,
    ) async {
      await pumpApp(tester);
      await openPanel(tester);
      for (final id in ['0011223344556677', '1122334455667788']) {
        await channel.receiveSecure(
          FileOfferFrame(
            sid: 's1',
            fid: id,
            name: '$id.txt',
            size: 1024,
            group: 'aaaabbbbccccdddd',
          ),
        );
      }
      await tester.pump();
      expect(find.byKey(const Key('overlay-offer')), findsOneWidget);
      expect(find.textContaining('Ctrl+O : accepter'), findsOneWidget);

      // Enter, while typing, is no answer.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(connection.sessions.single.pendingFiles, hasLength(2));

      await ctrl(tester, LogicalKeyboardKey.keyN);
      expect(connection.sessions.single.pendingFiles, isEmpty);
      expect(find.byKey(const Key('overlay-offer')), findsNothing);
      await cleanUp(tester);
    });
  });

  group('the camera in the panel', () {
    Future<void> watching(WidgetTester tester) async {
      await start(tester, 's1', alice);
      await tester.tap(find.byKey(const Key('live-toggle')));
      await tester.pump();
      await channel.receiveSecure(const LiveAcceptFrame(sid: 's1'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('enter-overlay')));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('shows on the left, at the initial height of the panel', (
      tester,
    ) async {
      await pumpApp(tester);
      await watching(tester);

      final view = tester.getRect(find.byKey(const Key('overlay-live')));
      expect(view.left, 0);
      expect(view.top, 0);
      expect(view.height, DesktopOverlay.panelHeight);
      expect(native, contains('liveView'));
      // The text moved over.
      final text = tester.getRect(find.byKey(const Key('overlay-input')));
      expect(text.left, greaterThanOrEqualTo(view.right));

      // A long text makes the panel grow, not the view.
      await channel.receiveSecure(
        DraftSnapshotFrame(sid: 's1', seq: 1, text: 'Oui, et toi ' * 30),
      );
      await rollOut(tester);
      expect(resized.last, greaterThan(DesktopOverlay.panelHeight));
      expect(
        tester.getSize(find.byKey(const Key('overlay-live'))).height,
        DesktopOverlay.panelHeight,
      );
      await cleanUp(tester);
    });

    testWidgets('a click and F11 go full screen, and back to the panel', (
      tester,
    ) async {
      await pumpApp(tester);
      await watching(tester);

      await tester.tap(find.byKey(const Key('overlay-live')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('live-fullscreen')), findsOneWidget);
      expect(overlay.active, isFalse);
      expect(system, [true]);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('live-fullscreen')), findsNothing);
      expect(overlay.active, isTrue);
      expect(panel, findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pump();
      await tester.pump();
      expect(fullscreen.active, isTrue);
      await fullscreen.exit();
      await tester.pump();
      await cleanUp(tester);
    });

    testWidgets('the global shortcut goes full screen', (tester) async {
      await pumpApp(tester);
      await watching(tester);
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        overlayChannel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('fullscreen'),
        ),
        (_) {},
      );
      await tester.pump();
      await tester.pump();
      expect(fullscreen.active, isTrue);
      await fullscreen.exit();
      await tester.pump();
      await cleanUp(tester);
    });

    testWidgets('a request is answered with Ctrl+O, never with Enter', (
      tester,
    ) async {
      await pumpApp(tester);
      await start(tester, 's1', alice);
      await tester.tap(find.byKey(const Key('enter-overlay')));
      await tester.pump();
      await tester.pump();
      await channel.receiveSecure(const LiveRequestFrame(sid: 's1'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      final live = connection.sessions.single.live;
      expect(find.byKey(const Key('overlay-live-request')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(live.share, LiveShare.asked);
      expect(camera.opened, isFalse);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 100));
      expect(camera.opened, isTrue);
      // A dot, no message.
      expect(find.byKey(const Key('overlay-sharing')), findsOneWidget);
      expect(find.textContaining('voit votre caméra'), findsNothing);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 100));
      expect(camera.closed, isTrue);
      expect(find.byKey(const Key('overlay-sharing')), findsNothing);
      await cleanUp(tester);
    });
  });

  test('unsupported platforms never change the window', () async {
    final calls = <String>[];
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(overlayChannel, (call) async {
          calls.add(call.method);
          return null;
        });
    final connection = ConnectionService(
      identity: IdentityService(MemoryStore()),
      serverUri: Uri.parse('ws://test/ws'),
      connect: (_) => ScriptedChannel(),
    );
    final overlay = DesktopOverlay(
      connection: connection,
      channel: overlayChannel,
      supported: false,
    );
    await overlay.enter(ChatSession(sid: 's1', peer: alice, send: (_) {}));
    expect(overlay.active, isFalse);
    expect(calls, isEmpty);
    overlay.dispose();
    connection.dispose();
  });
}
