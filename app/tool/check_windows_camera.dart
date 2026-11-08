// The real webcam through the C++ runner (live_camera.cpp, video_codec.cpp,
// live_video.cpp), and the speed of the whole chain, encryption and relay
// included:
//
//   cd app && flutter run -d windows -t tool/check_windows_camera.dart
//
// Prints each check and exits (code 0 when all pass). The webcam turns on for
// a few seconds; no frame is kept. Two in-memory identities talk through an
// in-process relay: the user's own ID is never used.
// --dart-define=RELAY=wss://… measures through a real relay.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dismessage/services/camera_capture.dart';
import 'package:dismessage/services/connection_service.dart';
import 'package:dismessage/services/identity_service.dart';
import 'package:dismessage/services/live_camera.dart';
import 'package:dismessage/services/live_link.dart';
import 'package:dismessage/services/live_video.dart';
import 'package:dismessage/services/live_video_io.dart';
import 'package:dismessage/services/media_devices.dart';
import 'package:dismessage/widgets/live_view.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:dismessage_server/dismessage_server.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;

var _failures = 0;

/// What the window shows: the decoded texture, to be captured.
final _screen = ValueNotifier<LivePicture?>(null);
final _boundary = GlobalKey();

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
/// running, whatever the moment it is asked for. JPEG only.
class _ReplayCamera implements LiveCamera {
  _ReplayCamera(this._jpeg);
  final Uint8List _jpeg;
  final _clock = Stopwatch()..start();
  int _count = 0;

  @override
  Future<void> open() async {}

  @override
  Future<Set<String>> encoders() async => const {};

  @override
  Future<void> setCaptureSide(int side) async {}

  @override
  Future<LiveCameraFrame?> nextFrame(LiveFrameRequest request) async {
    // The next image of its regular rhythm: those nobody asked for are gone,
    // as with a real camera, not delivered late in a burst.
    final period = 1000 / kLiveTargetFps;
    _count = (_clock.elapsedMilliseconds / period).floor() + 1;
    final at = _count * period;
    while (_clock.elapsedMilliseconds < at) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    return LiveCameraFrame(_jpeg);
  }

  @override
  Future<void> close() async {}
}

/// A tiny grey version of [image], upside down if [flip].
List<double> _grey(img.Image image, {bool flip = false}) {
  var small = img.copyResize(image, width: 32, height: 18);
  if (flip) small = img.flipVertical(small);
  return [for (final p in small) p.luminance.toDouble()];
}

/// How much two images look alike (correlation of tiny grey images, -1 to 1).
double _likeness(img.Image a, img.Image b, {bool flip = false}) {
  final x = _grey(a, flip: flip), y = _grey(b);
  final meanX = x.reduce((p, q) => p + q) / x.length;
  final meanY = y.reduce((p, q) => p + q) / y.length;
  var product = 0.0, sumX = 0.0, sumY = 0.0;
  for (var i = 0; i < x.length; i++) {
    product += (x[i] - meanX) * (y[i] - meanY);
    sumX += (x[i] - meanX) * (x[i] - meanX);
    sumY += (y[i] - meanY) * (y[i] - meanY);
  }
  final scale = math.sqrt(sumX * sumY);
  return scale == 0 ? 0 : product / scale;
}

/// Average red, green and blue of [image].
List<double> _meanColour(img.Image image) {
  final sums = [0.0, 0.0, 0.0];
  var count = 0;
  for (final p in img.copyResize(image, width: 64)) {
    sums[0] += p.r;
    sums[1] += p.g;
    sums[2] += p.b;
    count++;
  }
  return [for (final s in sums) s / count];
}

Future<img.Image> _fromUi(ui.Image image) async {
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  return img.Image.fromBytes(
    width: image.width,
    height: image.height,
    bytes: bytes.buffer,
    numChannels: 4,
  );
}

bool isJpeg(Uint8List bytes) =>
    bytes.length > 4 && bytes[0] == 0xFF && bytes[1] == 0xD8;

/// NAL unit types of an Annex B access unit.
Set<int> nalTypes(Uint8List unit) => {
  for (var i = 0; i + 3 < unit.length; i++)
    if (unit[i] == 0 && unit[i + 1] == 0 && unit[i + 2] == 1)
      unit[i + 3] & 0x1F,
};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: _boundary,
        child: LiveSurface(image: _screen, fit: BoxFit.fill),
      ),
    ),
  );
  try {
    final cameras = await platformMediaDevices().cameras();
    stdout.writeln('Caméras : ${cameras.map((c) => c.label).join(', ')}');
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

    // The default camera alone, in JPEG.
    final camera = platformLiveCamera()!;
    await camera.open();
    const small = LiveFrameRequest(side: kLiveMaxSide);
    final warmup = Stopwatch()..start();
    while (warmup.elapsedMilliseconds < 1000) {
      final frame = await camera.nextFrame(small);
      if (frame != null && warmup.elapsedMilliseconds < 100) {
        check(isJpeg(frame.data), 'la caméra donne des JPEG');
      }
    }
    const stats = MethodChannel('dismessage/camera');
    Future<Map<Object?, Object?>> readStats() async =>
        (await stats.invokeMapMethod<Object?, Object?>('stats'))!;
    final before = await readStats();
    var count = 0;
    final clock = Stopwatch()..start();
    while (clock.elapsedMilliseconds < 3000) {
      if (await camera.nextFrame(small) != null) count++;
    }
    final perSecond = count / (clock.elapsedMilliseconds / 1000);
    final after = await readStats();
    final delivered =
        ((after['samples']! as int) - (before['samples']! as int)) /
        (clock.elapsedMilliseconds / 1000);
    stdout.writeln(
      'La caméra livre ${delivered.toStringAsFixed(1)} images/s, en '
      '${after['width']} × ${after['height']} ; '
      '${perSecond.toStringAsFixed(1)} récupérées.',
    );
    check(
      perSecond >= delivered - 2,
      'aucune image de la caméra perdue (une pièce sombre fait baisser ce que '
      'livre la caméra)',
    );
    final sample = (await camera.nextFrame(small))!.data;

    // H.264: encoded by the camera's thread, decoded by the runner.
    final encoders = await camera.encoders();
    check(encoders.contains(kLiveCodecH264), 'Windows encode le H.264');
    final decoders = await const ChannelLiveVideoCodecs().decoders();
    check(decoders.contains(kLiveCodecH264), 'Windows décode le H.264');
    await camera.setCaptureSide(kLiveFullSide);
    await Future<void>.delayed(const Duration(seconds: 2));
    for (final (side, kbps) in [
      (kLiveVideoSmallSide, kLiveStartKbps),
      (kLiveVideoFullStartSide, kLiveFullStartKbps),
      (kLiveFullSide, LiveFlow.maxKbpsFor(kLiveFullSide)),
    ]) {
      final decoder = const ChannelLiveVideoCodecs().create(kLiveCodecH264)!;
      final run = Stopwatch()..start();
      var frames = 0, bytes = 0, keys = 0, shown = 0;
      LivePicture? last;
      Uint8List? firstUnit;
      var request = LiveFrameRequest(
        side: side,
        codec: kLiveCodecH264,
        kbps: kbps,
        key: true,
      );
      var askedKey = false, keyOnDemand = false;
      final decodeTime = Stopwatch();
      while (run.elapsedMilliseconds < 4000) {
        final frame = await camera.nextFrame(request);
        if (frame == null) continue;
        firstUnit ??= frame.data;
        frames++;
        bytes += frame.data.length;
        if (frame.key) keys++;
        if (askedKey && frame.key) keyOnDemand = true;
        askedKey = false;
        decodeTime.start();
        final picture = await decoder.decode(
          frame.data,
          key: frame.key,
          rotation: frame.rotation,
        );
        decodeTime.stop();
        if (picture != null) {
          shown++;
          last = picture;
        }
        // Half way: a key frame on demand, as the viewer would ask.
        final halfWay = run.elapsedMilliseconds > 2000 && !keyOnDemand;
        request = LiveFrameRequest(
          side: side,
          codec: kLiveCodecH264,
          kbps: kbps,
          key: halfWay,
          preview: frames % 8 == 0,
        );
        askedKey = halfWay;
      }
      final seconds = run.elapsedMilliseconds / 1000;
      final first = firstUnit ?? Uint8List(0);
      check(
        nalTypes(first).containsAll({7, 8, 5}),
        '$side px : la première image est une image clé avec ses paramètres '
        '(${nalTypes(first)})',
      );
      check(keyOnDemand, '$side px : une image clé à la demande');
      final picture = last;
      final longest = picture == null
          ? 0
          : math.max(picture.width, picture.height);
      check(
        picture?.texture != null &&
            (longest - math.min(side, longest)).abs() <= 2,
        '$side px : décodée en ${picture?.width} × ${picture?.height}',
      );
      final kbpsMeasured = bytes * 8 / seconds / 1000;
      check(
        kbpsMeasured < kbps * 1.6,
        '$side px : ${(frames / seconds).toStringAsFixed(1)} images/s, '
        '${kbpsMeasured.round()} kbit/s pour $kbps demandés, $keys clé(s), '
        '${shown == 0 ? 0 : decodeTime.elapsedMilliseconds ~/ shown} ms de '
        'décodage par image',
      );
      check(
        shown >= frames - 1,
        '$side px : chaque image décodée aussitôt ($shown sur $frames)',
      );
      if (picture != null && side == kLiveVideoFullStartSide) {
        // Same scene in JPEG: the video is upright, in the right colours.
        // The texture as the overlay panel captures it: a snapshot of what
        // Flutter draws.
        final jpeg = img.decodeJpg(
          (await camera.nextFrame(LiveFrameRequest(side: side)))!.data,
        )!;
        _screen.value = picture;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final boundary =
            _boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final snapshot = await boundary.toImage();
        final video = await _fromUi(snapshot);
        snapshot.dispose();
        _screen.value = null;
        final straight = _likeness(video, jpeg);
        final flipped = _likeness(video, jpeg, flip: true);
        check(
          straight > 0.8 && straight > flipped,
          'vidéo à l’endroit, comme le JPEG (ressemblance '
          '${straight.toStringAsFixed(2)}, à l’envers '
          '${flipped.toStringAsFixed(2)})',
        );
        final a = _meanColour(video), b = _meanColour(jpeg);
        final gap = [for (var i = 0; i < 3; i++) (a[i] - b[i]).abs()];
        check(
          gap.every((g) => g < 20),
          'mêmes couleurs que le JPEG (écart rouge / vert / bleu : '
          '${gap.map((g) => g.round()).join(' / ')})',
        );
      }
      await decoder.close();
    }
    // A broken stream is refused, not shown.
    final broken = const ChannelLiveVideoCodecs().create(kLiveCodecH264)!;
    var refused = false;
    try {
      for (var i = 0; i < 3; i++) {
        await broken.decode(
          Uint8List.fromList([0, 0, 0, 1, 0x65, ...List.filled(64, i * 37)]),
          key: true,
          rotation: 0,
        );
      }
    } catch (_) {
      refused = true;
    }
    check(true, 'un flux illisible ne fait pas planter (refusé : $refused)');
    await broken.close();
    await camera.close();

    // The right way up: compared, in tiny grey images never shown or kept,
    // with a photo from `camera_windows`, whose orientation is known.
    await Future<void>.delayed(const Duration(seconds: 2));
    final photoCamera = platformCameraCapture();
    if (photoCamera != null) {
      await photoCamera.open();
      await Future<void>.delayed(const Duration(seconds: 2));
      final photo = img.decodeImage(await photoCamera.takePicture())!;
      await photoCamera.close();
      final upright = img.decodeJpg(sample)!;
      final straight = _likeness(upright, photo);
      final flipped = _likeness(upright, photo, flip: true);
      check(
        straight > flipped,
        'image à l’endroit (ressemblance à une photo : '
        '${straight.toStringAsFixed(2)}, à l’envers : '
        '${flipped.toStringAsFixed(2)})',
      );
      await Future<void>.delayed(const Duration(seconds: 2));
    }

    // The whole chain: camera → encryption → relay → decoding → display.
    final server = await serve(
      Relay(IdStore.memory()),
      address: 'localhost',
      port: 0,
    );
    const relay = String.fromEnvironment('RELAY');
    final uri = relay.isEmpty
        ? Uri.parse('ws://localhost:${server.port}/ws')
        : Uri.parse(relay);
    stdout.writeln('Relais : $uri');
    LiveCamera? replay;
    var viewerVideo = true;
    final owner = ConnectionService(
      identity: IdentityService(MemoryStore()),
      serverUri: uri,
      createLiveCamera: () => replay ?? platformLiveCamera(),
    );
    final viewer = ConnectionService(
      identity: IdentityService(MemoryStore()),
      serverUri: uri,
      liveVideo: _Switchable(() => viewerVideo),
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
    final sharing = owner.sessions.single.live;
    var shown = 0;
    final beat = Stopwatch()..start();
    var gaps = <int>[];
    var lastBeat = 0;
    void onFrame() {
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

    String network() {
      final flow = sharing.flow;
      return 'délai ${flow?.lowestRtt}-${flow?.lastRtt} ms, ${flow?.window} en '
          'route';
    }

    Future<void> start() async {
      shown = 0;
      watching.request();
      await waitFor(() => sharing.share == LiveShare.asked, 'request');
      sharing.acceptRequest();
      await waitFor(() => watching.watch == LiveWatch.watching, 'accepted');
      await waitFor(() => shown > 0, 'first frame');
    }

    Future<void> stop() async {
      watching.stopWatching();
      await waitFor(() => sharing.share == LiveShare.idle, 'stop');
    }

    // As a view on screen would: nothing is decoded for a hidden one.
    void looking() {}
    watching.image.addListener(looking);
    watching.shown.addListener(onFrame);

    // Video, with this camera.
    await start();
    check(
      watching.codec == kLiveCodecH264 && sharing.sharedCodec == kLiveCodecH264,
      'les deux côtés choisissent le H.264',
    );
    var picture = watching.image.value!;
    check(
      math.max(picture.width, picture.height) == kLiveVideoSmallSide,
      'vue réduite en vidéo : ${picture.width} × ${picture.height}',
    );
    var from = shown;
    await Future<void>.delayed(const Duration(seconds: 4));
    gaps = [];
    await Future<void>.delayed(const Duration(seconds: 4));
    check(
      (shown - from) / 8 >= delivered - 4,
      'vidéo de bout en bout, chiffrée : ${(gaps.length / 4).toStringAsFixed(1)} '
      'images/s à ${sharing.flow?.kbps} kbit/s, ${regularity()} ; ${network()}',
    );
    watching.setFullView(true);
    await Future<void>.delayed(const Duration(seconds: 6));
    gaps = [];
    from = shown;
    await Future<void>.delayed(const Duration(seconds: 4));
    picture = watching.image.value!;
    check(
      math.max(picture.width, picture.height) >= kLiveVideoFullStartSide,
      'plein écran en vidéo : ${picture.width} × ${picture.height} '
      '(taille visée ${sharing.flow?.side}, ${sharing.flow?.kbps} kbit/s), '
      '${(gaps.length / 4).toStringAsFixed(1)} images/s, ${regularity()} ; '
      '${network()}',
    );
    await stop();
    check(true, 'fermer la vue éteint la caméra de l’autre');

    // JPEG, as with an older version: what the chain can do, whatever the
    // light, with one real image at 30 per second.
    viewerVideo = false;
    replay = _ReplayCamera(sample);
    await start();
    check(watching.codec == null, 'une version sans vidéo reçoit du JPEG');
    from = shown;
    await Future<void>.delayed(const Duration(seconds: 5));
    gaps = [];
    final capacity = (shown - from) / 5;
    check(
      capacity >= kLiveTargetFps - 3,
      'capacité de la chaîne en JPEG : ${capacity.toStringAsFixed(1)} '
      'images/s (objectif $kLiveTargetFps)',
    );
    await Future<void>.delayed(const Duration(seconds: 5));
    stdout.writeln(
      'JPEG (${sample.length ~/ 1024} Ko) : '
      '${(gaps.length / 5).toStringAsFixed(1)} images/s, ${regularity()} ; '
      '${network()}',
    );
    watching.shown.removeListener(onFrame);
    watching.image.removeListener(looking);
    await stop();
    owner.dispose();
    viewer.dispose();
    await server.close(force: true);
  } catch (e, stack) {
    check(false, 'exception : $e\n$stack');
  }
  stdout.writeln(_failures == 0 ? 'TOUT EST BON' : '$_failures ÉCHEC(S)');
  exit(_failures == 0 ? 0 : 1);
}

/// The platform's decoders, or none (an older version) when [video] says so.
class _Switchable implements LiveVideoCodecs {
  _Switchable(this.video);
  final bool Function() video;
  static const _platform = ChannelLiveVideoCodecs();

  @override
  Future<Set<String>> decoders() =>
      video() ? _platform.decoders() : SynchronousFuture(const {});

  @override
  LiveVideoDecoder? create(String codec) =>
      video() ? _platform.create(codec) : null;
}
