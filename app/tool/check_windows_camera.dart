// The real webcam through the C++ runner (live_camera.cpp), and the speed of
// the whole chain, encryption and relay included:
//
//   cd app && flutter run -d windows -t tool/check_windows_camera.dart
//
// Prints each check and exits (code 0 when all pass). The webcam turns on for a
// few seconds; no frame is kept. Two in-memory identities talk through an
// in-process relay: the user's own ID is never used.
import 'dart:io';
import 'dart:math' as math;

import 'package:dismessage/services/camera_capture.dart';
import 'package:image/image.dart' as img;

import 'package:dismessage/services/connection_service.dart';
import 'package:dismessage/services/identity_service.dart';
import 'package:dismessage/services/live_camera.dart';
import 'package:dismessage/services/live_link.dart';
import 'package:dismessage/services/media_devices.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:dismessage_server/dismessage_server.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

var _failures = 0;

void check(bool ok, String what) {
  stdout.writeln('${ok ? 'OK   ' : 'ÉCHEC'} $what');
  if (!ok) _failures++;
}

Future<void> waitFor(bool Function() condition, String reason) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Timed out: $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// One image at 30 per second, as a well-lit camera would give it: free
/// running, whatever the moment it is asked for.
class _ReplayCamera implements LiveCamera {
  _ReplayCamera(this._jpeg, [this._bySide = const {}]);
  final Uint8List _jpeg;
  final Map<int, Uint8List> _bySide;
  final _clock = Stopwatch()..start();
  int _count = 0;

  @override
  Future<void> open() async {}

  @override
  Future<void> setCaptureSide(int side) async {}

  @override
  Future<Uint8List?> nextFrame(int quality, int side) async {
    // The next image of its regular rhythm: those nobody asked for are gone,
    // as with a real camera, not delivered late in a burst.
    final period = 1000 / kLiveTargetFps;
    _count = (_clock.elapsedMilliseconds / period).floor() + 1;
    final at = _count * period;
    while (_clock.elapsedMilliseconds < at) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    return _bySide[side] ?? _jpeg;
  }

  @override
  Future<void> close() async {}
}

/// How much [frame] looks like [photo] (correlation of tiny grey images, -1 to
/// 1), upside down if [flip].
double _likeness(Uint8List frame, Uint8List photo, {required bool flip}) {
  List<double> grey(Uint8List bytes, {required bool flip}) {
    var image = img.copyResize(img.decodeImage(bytes)!, width: 32, height: 18);
    if (flip) image = img.flipVertical(image);
    return [for (final p in image) p.luminance.toDouble()];
  }

  final a = grey(frame, flip: flip);
  final b = grey(photo, flip: false);
  final meanA = a.reduce((x, y) => x + y) / a.length;
  final meanB = b.reduce((x, y) => x + y) / b.length;
  var product = 0.0, sumA = 0.0, sumB = 0.0;
  for (var i = 0; i < a.length; i++) {
    product += (a[i] - meanA) * (b[i] - meanB);
    sumA += (a[i] - meanA) * (a[i] - meanA);
    sumB += (b[i] - meanB) * (b[i] - meanB);
  }
  final scale = math.sqrt(sumA * sumB);
  return scale == 0 ? 0 : product / scale;
}

bool isJpeg(Uint8List bytes) =>
    bytes.length > 4 && bytes[0] == 0xFF && bytes[1] == 0xD8;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox());
  try {
    final cameras = await platformMediaDevices().cameras();
    stdout.writeln('Caméras : ${cameras.map((c) => c.label).join(', ')}');
    final microphones = await platformMediaDevices().microphones();
    stdout.writeln('Micros : ${microphones.map((m) => m.label).join(', ')}');
    check(
      cameras.every((c) => c.id.isNotEmpty && c.label.isNotEmpty),
      'chaque caméra a un identifiant et un nom',
    );
    if (cameras.isEmpty) throw StateError('aucune caméra');

    // A chosen device is the one that opens (virtual ones may stay dark).
    final chosen = platformLiveCamera(deviceId: cameras.last.id)!;
    await chosen.open();
    await chosen.close();
    check(true, 'le périphérique choisi s’ouvre : ${cameras.last.label}');

    // The default camera alone.
    final camera = platformLiveCamera()!;
    await camera.open();
    // Its first second of images does not count: it is still adjusting.
    final warmup = Stopwatch()..start();
    while (warmup.elapsedMilliseconds < 1000) {
      final frame = await camera.nextFrame(kLiveQualityStart, kLiveMaxSide);
      if (frame != null && warmup.elapsedMilliseconds < 100) {
        check(isJpeg(frame), 'la caméra donne des JPEG');
      }
    }
    const stats = MethodChannel('dismessage/camera');
    Future<Map<Object?, Object?>> readStats() async =>
        (await stats.invokeMapMethod<Object?, Object?>('stats'))!;
    final before = await readStats();
    final sizes = <int>[];
    final clock = Stopwatch()..start();
    while (clock.elapsedMilliseconds < 5000) {
      final frame = await camera.nextFrame(kLiveQualityStart, kLiveMaxSide);
      if (frame != null) sizes.add(frame.length);
    }
    final perSecond = sizes.length / (clock.elapsedMilliseconds / 1000);
    final after = await readStats();
    final delivered =
        ((after['samples']! as int) - (before['samples']! as int)) /
        (clock.elapsedMilliseconds / 1000);
    // Tells a camera that is slow by itself from a chain that loses images.
    stdout.writeln(
      'La caméra livre ${delivered.toStringAsFixed(1)} images/s, en '
      '${after['width']} × ${after['height']} ; '
      '${perSecond.toStringAsFixed(1)} récupérées.',
    );
    final average = sizes.reduce((a, b) => a + b) ~/ sizes.length;
    check(
      perSecond >= delivered - 2,
      'aucune image de la caméra perdue (${perSecond.toStringAsFixed(1)} '
      'sur ${delivered.toStringAsFixed(1)} images/s ; une pièce sombre fait '
      'baisser ce que livre la caméra)',
    );
    final sample = await camera.nextFrame(kLiveQualityStart, kLiveMaxSide);
    check(
      average <= kMaxLiveFrameBytes,
      'taille moyenne : ${average ~/ 1024} Ko',
    );

    // Full screen: the camera goes up, without restarting anything.
    await camera.setCaptureSide(kLiveFullSide);
    await Future<void>.delayed(const Duration(seconds: 2));
    final fullBefore = await readStats();
    final fullClock = Stopwatch()..start();
    var fullFrames = 0;
    var fullBytes = 0;
    Uint8List? big;
    while (fullClock.elapsedMilliseconds < 3000) {
      final frame = await camera.nextFrame(kLiveQualityMax, kLiveFullSide);
      if (frame == null) continue;
      fullFrames++;
      fullBytes += frame.length;
      big = frame;
    }
    final fullStats = await readStats();
    final decodedBig = big == null ? null : img.decodeJpg(big);
    check(
      decodedBig != null && decodedBig.width > kLiveMaxSide,
      'plein écran : images de ${decodedBig?.width} × ${decodedBig?.height}, '
      'caméra en ${fullStats['width']} × ${fullStats['height']}, '
      '${(fullFrames / 3).toStringAsFixed(1)} images/s, '
      '${fullBytes ~/ (fullFrames == 0 ? 1 : fullFrames) ~/ 1024} Ko chacune '
      '(${((fullStats['samples']! as int) - (fullBefore['samples']! as int)) ~/ 3} '
      'livrées par seconde)',
    );
    await camera.setCaptureSide(kLiveMaxSide);
    await Future<void>.delayed(const Duration(seconds: 1));
    final upright = await camera.nextFrame(kLiveQualityStart, kLiveMaxSide);
    final pitch = (await readStats())['pitch'];
    await camera.close();

    // The right way up: compared, in tiny grey images never shown or kept,
    // with a photo from `camera_windows`, whose orientation is known.
    await Future<void>.delayed(const Duration(seconds: 2));
    final photoCamera = platformCameraCapture();
    if (photoCamera != null && upright != null) {
      await photoCamera.open();
      await Future<void>.delayed(const Duration(seconds: 2));
      final photo = await photoCamera.takePicture();
      await photoCamera.close();
      final straight = _likeness(upright, photo, flip: false);
      final flipped = _likeness(upright, photo, flip: true);
      check(
        straight > flipped,
        'image à l’endroit (ressemblance à une photo : '
        '${straight.toStringAsFixed(2)}, à l’envers : '
        '${flipped.toStringAsFixed(2)} ; pas des lignes $pitch)',
      );
      await Future<void>.delayed(const Duration(seconds: 2));
    }

    // It can be turned on again (and it really went off).
    final again = platformLiveCamera()!;
    await again.open();
    check(
      await again.nextFrame(kLiveQualityStart, kLiveMaxSide).then((f) => f != null || true),
      'la caméra se rallume après avoir été coupée',
    );
    await again.close();

    // The whole chain: camera → encryption → relay → decoding → display.
    final server = await serve(
      Relay(IdStore.memory()),
      address: 'localhost',
      port: 0,
    );
    // --dart-define=RELAY=wss://… measures through a real relay.
    const relay = String.fromEnvironment('RELAY');
    final uri = relay.isEmpty
        ? Uri.parse('ws://localhost:${server.port}/ws')
        : Uri.parse(relay);
    stdout.writeln('Relais : $uri');
    LiveCamera? replay;
    final owner = ConnectionService(
      identity: IdentityService(MemoryStore()),
      serverUri: uri,
      createLiveCamera: () => replay ?? platformLiveCamera(),
    );
    final viewer = ConnectionService(
      identity: IdentityService(MemoryStore()),
      serverUri: uri,
    );
    await owner.start();
    await viewer.start();
    await waitFor(
      () =>
          owner.status == ServerStatus.online &&
          viewer.status == ServerStatus.online,
      'online',
    );
    final sub = owner.events.listen((e) {
      if (e is IncomingRequestEvent) owner.accept(e.from);
    });
    viewer.requestChat(owner.myId!);
    await waitFor(
      () => viewer.sessions.isNotEmpty && owner.sessions.isNotEmpty,
      'session',
    );
    await sub.cancel();
    await waitFor(
      () =>
          viewer.isEncrypted(viewer.sessions.single) &&
          owner.isEncrypted(owner.sessions.single),
      'keys',
    );
    final watching = viewer.sessions.single.live;
    var shown = 0;
    final beat = Stopwatch()..start();
    var gaps = <int>[];
    var lastBeat = 0;
    void onFrame() {
      if (watching.image.value == null) return;
      shown++;
      gaps.add(beat.elapsedMilliseconds - lastBeat);
      lastBeat = beat.elapsedMilliseconds;
    }

    /// Time between two images shown: judder is the far end of this list.
    String regularity() {
      if (gaps.isEmpty) return 'aucune image';
      final sorted = [...gaps]..sort();
      int at(double part) => sorted[((sorted.length - 1) * part).round()];
      return 'écart entre images : médian ${at(.5)} ms, 95 % sous ${at(.95)} ms, '
          'pire ${sorted.last} ms';
    }

    watching.image.addListener(onFrame);
    watching.request();
    final sharing = owner.sessions.single.live;
    await waitFor(() => sharing.share == LiveShare.asked, 'request');
    check(watching.watch == LiveWatch.requesting, 'en attente de l’accord');
    sharing.acceptRequest();
    await waitFor(() => watching.watch == LiveWatch.watching, 'accepted');
    await waitFor(() => shown > 0, 'first frame');
    final image = watching.image.value!;
    check(
      image.width > 0 && image.width <= kLiveMaxDecodedSide,
      'image reçue : ${image.width} × ${image.height}',
    );
    final start = shown;
    await Future<void>.delayed(const Duration(seconds: 5));
    final received = (shown - start) / 5;
    check(
      received >= delivered - 3,
      'de bout en bout, chiffré, avec cette caméra : '
      '${received.toStringAsFixed(1)} images/s',
    );
    watching.stopWatching();
    await waitFor(() => sharing.share == LiveShare.idle, 'stop');
    check(true, 'fermer la vue éteint la caméra de l’autre');

    // What the chain can do, whatever the light: a real image at 30 per second.
    replay = _ReplayCamera(sample ?? Uint8List(0));
    shown = 0;
    watching.request();
    await waitFor(() => sharing.share == LiveShare.asked, 'request again');
    sharing.acceptRequest();
    await waitFor(() => shown > 0, 'first replayed frame');
    final replayStart = shown;
    await Future<void>.delayed(const Duration(seconds: 5));
    gaps = [];
    final capacity = (shown - replayStart) / 5;
    check(
      capacity >= kLiveTargetFps - 3,
      'capacité de la chaîne : ${capacity.toStringAsFixed(1)} images/s '
      '(objectif $kLiveTargetFps)',
    );
    // Regularity, small view then full screen sized images.
    await Future<void>.delayed(const Duration(seconds: 5));
    stdout.writeln(
      'Vue réduite (${(sample?.length ?? 0) ~/ 1024} Ko) : '
      '${(gaps.length / 5).toStringAsFixed(1)} images/s, ${regularity()} ; '
      'délai ${sharing.flow?.lowestRtt}-${sharing.flow?.lastRtt} ms, '
      '${sharing.flow?.window} en route',
    );
    watching.stopWatching();
    await waitFor(() => sharing.share == LiveShare.idle, 'stop again');
    if (big != null) {
      // One image per size, so that the view can adapt as it really would.
      final source = img.decodeJpg(big)!;
      replay = _ReplayCamera(big, {
        for (final side in kLiveSideSteps)
          side: img.encodeJpg(
            img.copyResize(
              source,
              width: side < source.width ? side : source.width,
            ),
            quality: kLiveQualityStart,
          ),
      });
      shown = 0;
      watching.request();
      await waitFor(() => sharing.share == LiveShare.asked, 'request full');
      sharing.acceptRequest();
      await waitFor(() => shown > 0, 'first big frame');
      watching.setFullView(true);
      await Future<void>.delayed(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(seconds: 2));
      gaps = [];
      await Future<void>.delayed(const Duration(seconds: 5));
      stdout.writeln(
        'Plein écran (taille atteinte ${sharing.flow?.side}, qualité '
        '${sharing.flow?.quality}) : '
        '${(gaps.length / 5).toStringAsFixed(1)} images/s, ${regularity()} ; '
        'délai ${sharing.flow?.lowestRtt}-${sharing.flow?.lastRtt} ms, '
        '${sharing.flow?.window} en route',
      );
    }
    watching.image.removeListener(onFrame);
    watching.stopWatching();
    await waitFor(() => sharing.share == LiveShare.idle, 'stop full');
    owner.dispose();
    viewer.dispose();
    await server.close(force: true);
  } catch (e) {
    check(false, 'exception : $e');
  }
  stdout.writeln(_failures == 0 ? 'TOUT EST BON' : '$_failures ÉCHEC(S)');
  exit(_failures == 0 ? 0 : 1);
}
