// The browser's H.264 (WebCodecs) for real, with the web camera of the app:
//
//   cd app && flutter build web -t tool/check_web_video.dart --no-web-resources-cdn -o <dossier>
//
// then open the page in Chrome (a fake camera does: --use-fake-device-for-
// media-stream --use-fake-ui-for-media-stream). Each check is printed in the
// console and sent to `POST /result` when the page is served by a test server;
// the last line is TOUT EST BON or N ÉCHEC(S).
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dismessage/services/live_camera.dart';
import 'package:dismessage/services/live_camera_web.dart';
import 'package:dismessage/services/live_video_web.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

final _lines = <String>[];
var _failures = 0;

void report(String line) {
  _lines.add(line);
  // ignore: avoid_print
  print(line);
}

void check(bool ok, String what) {
  report('${ok ? 'OK   ' : 'ÉCHEC'} $what');
  if (!ok) _failures++;
}

/// A canvas whose left half is red and right half blue, with a white square
/// that moves with [frame].
web.HTMLCanvasElement pattern(int width, int height, int frame) {
  final canvas = web.HTMLCanvasElement()
    ..width = width
    ..height = height;
  final context = canvas.getContext('2d')! as web.CanvasRenderingContext2D;
  context.fillStyle = 'rgb(220, 20, 20)'.toJS;
  context.fillRect(0, 0, width / 2, height);
  context.fillStyle = 'rgb(20, 20, 220)'.toJS;
  context.fillRect(width / 2, 0, width / 2, height);
  context.fillStyle = 'white'.toJS;
  context.fillRect(10 + frame * 4, height / 2 - 20, 40, 40);
  return canvas;
}

/// Red, green and blue at ([x], [y]) of [image].
Future<List<int>> pixel(ui.Image image, int x, int y) async {
  final bytes = (await image.toByteData())!;
  final at = (y * image.width + x) * 4;
  return [bytes.getUint8(at), bytes.getUint8(at + 1), bytes.getUint8(at + 2)];
}

/// NAL unit types of an Annex B access unit.
Set<int> nalTypes(Uint8List unit) => {
  for (var i = 0; i + 3 < unit.length; i++)
    if (unit[i] == 0 && unit[i + 1] == 0 && unit[i + 2] == 1)
      unit[i + 3] & 0x1F,
};

Future<void> codecs() async {
  check(
    (await WebH264Encoder.codecs()).contains(kLiveCodecH264),
    'le navigateur encode le H.264',
  );
  check(
    (await const WebLiveVideoCodecs().decoders()).contains(kLiveCodecH264),
    'le navigateur décode le H.264',
  );
}

Future<void> pattern640() async {
  final encoder = WebH264Encoder();
  final decoder = WebLiveVideoDecoder();
  ui.Image? last;
  var keys = 0, firstHasParameters = false, keyOnDemand = false;
  var bytes = 0;
  for (var frame = 0; frame < 30; frame++) {
    final encoded = await encoder.encode(
      pattern(640, 360, frame),
      640,
      360,
      kbps: kLiveStartKbps,
      key: frame == 20,
    );
    if (encoded == null) continue;
    bytes += encoded.data.length;
    if (frame == 0) {
      firstHasParameters =
          encoded.key && nalTypes(encoded.data).containsAll([7, 8, 5]);
    }
    if (frame == 20) keyOnDemand = encoded.key;
    if (encoded.key) keys++;
    final picture = await decoder.decode(
      encoded.data,
      key: encoded.key,
      rotation: 90,
    );
    if (picture != null) {
      last?.dispose();
      last = picture.image;
    }
  }
  check(firstHasParameters, 'la première image est une image clé complète');
  check(keyOnDemand, 'une image clé à la demande');
  check(keys < 6, 'les autres sont des différences ($keys clé(s) sur 30)');
  final image = last;
  check(
    image != null && image.width == 640 && image.height == 360,
    'décodée en ${image?.width} × ${image?.height} '
    '(${bytes ~/ 30} octets par image)',
  );
  if (image != null) {
    final red = await pixel(image, 100, 40);
    final blue = await pixel(image, 540, 40);
    check(
      red[0] > 170 && red[2] < 70 && blue[2] > 170 && blue[0] < 70,
      'couleurs justes (rouge $red, bleu $blue)',
    );
    image.dispose();
  }
  encoder.close();
  await decoder.close();
}

Future<void> newSize() async {
  final encoder = WebH264Encoder();
  await encoder.encode(
    pattern(640, 360, 0),
    640,
    360,
    kbps: kLiveStartKbps,
    key: false,
  );
  final larger = await encoder.encode(
    pattern(1280, 720, 1),
    1280,
    720,
    kbps: kLiveFullStartKbps,
    key: false,
  );
  check(larger?.key ?? false, 'une nouvelle taille repart d’une image clé');
  encoder.close();
}

Future<void> broken() async {
  final decoder = WebLiveVideoDecoder();
  var shown = 0;
  Object? error;
  try {
    for (var i = 0; i < 3; i++) {
      final picture = await decoder.decode(
        Uint8List.fromList([0, 0, 0, 1, 0x65, ...List.filled(64, i * 37)]),
        key: true,
        rotation: 0,
      );
      if (picture != null) shown++;
    }
  } catch (e) {
    error = e;
  }
  check(
    shown == 0,
    'un flux illisible ne montre rien, la page continue '
    '(${error == null ? 'ignoré' : 'refusé'})',
  );
  await decoder.close();
}

/// The app's web camera (getUserMedia → canvas → WebCodecs), as the live
/// view uses it.
Future<void> camera() async {
  final camera = WebLiveCamera(null);
  await camera.open();
  check(
    (await camera.encoders()).contains(kLiveCodecH264),
    'la caméra web propose le H.264',
  );
  await camera.setCaptureSide(kLiveFullSide);
  final decoder = WebLiveVideoDecoder();
  final clock = Stopwatch()..start();
  var frames = 0, shown = 0, bytes = 0;
  final capture = Stopwatch(), decoding = Stopwatch();
  var preview = false, firstKey = false;
  ui.Image? last;
  for (var i = 0; clock.elapsedMilliseconds < 4000; i++) {
    capture.start();
    final frame = await camera.nextFrame(
      LiveFrameRequest(
        side: kLiveVideoFullStartSide,
        codec: kLiveCodecH264,
        kbps: kLiveFullStartKbps,
        key: i == 0,
        preview: i % 8 == 0,
      ),
    );
    capture.stop();
    if (frame == null) continue;
    if (frames == 0) firstKey = frame.key;
    frames++;
    bytes += frame.data.length;
    if (frame.preview != null) preview = true;
    decoding.start();
    final picture = await decoder.decode(
      frame.data,
      key: frame.key,
      rotation: frame.rotation,
    );
    decoding.stop();
    if (picture != null) {
      shown++;
      last?.dispose();
      last = picture.image;
    }
  }
  final seconds = clock.elapsedMilliseconds / 1000;
  check(firstKey, 'caméra : la première image est une image clé');
  check(preview, 'caméra : la vignette accompagne une image sur huit');
  final image = last;
  check(
    image != null && math.max(image.width, image.height) > kLiveVideoSmallSide,
    'caméra : ${image?.width} × ${image?.height}, '
    '${(frames / seconds).toStringAsFixed(1)} images/s, '
    '${(bytes * 8 / seconds / 1000).round()} kbit/s, $shown décodées '
    'sur $frames ; ${capture.elapsedMilliseconds ~/ math.max(1, frames)} ms '
    'pour capturer et encoder, ${decoding.elapsedMilliseconds ~/ math.max(1, shown)} '
    'ms pour décoder',
  );
  image?.dispose();
  await decoder.close();
  await camera.close();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox());
  for (final step in [codecs, pattern640, newSize, broken, camera]) {
    try {
      await step();
    } catch (e) {
      check(false, 'exception : $e');
    }
  }
  report(_failures == 0 ? 'TOUT EST BON' : '$_failures ÉCHEC(S)');
  final text = _lines.join('\n');
  try {
    await web.window
        .fetch('/result'.toJS, web.RequestInit(method: 'POST', body: text.toJS))
        .toDart;
  } catch (_) {
    // Not served by a test server: the console has it.
  }
}
