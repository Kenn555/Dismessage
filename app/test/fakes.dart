import 'dart:async';
import 'dart:typed_data';

import 'package:dismessage/services/attachments.dart';
import 'package:dismessage/services/camera_capture.dart';
import 'package:dismessage/services/chat_session.dart';
import 'package:dismessage/services/clipboard_images.dart';
import 'package:dismessage/services/file_storage.dart';
import 'package:dismessage/services/live_camera.dart';
import 'package:dismessage/services/live_picture.dart';
import 'package:dismessage/services/live_video.dart';
import 'package:dismessage/services/voice_player.dart';
import 'package:dismessage/services/voice_recorder.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Records what the app sends.
class RecordingSink implements WebSocketSink {
  final sent = <Frame>[];

  @override
  void add(Object? data) => sent.add(Frame.decode(data));

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A connected channel whose server side is driven by the test.
///
/// It can also play the peer of encrypted conversations: [startSession]
/// opens one with a key exchange, [receiveSecure] seals what the peer says,
/// [openedSent] decrypts what the app said.
class ScriptedChannel implements WebSocketChannel {
  ScriptedChannel();

  /// A new connection of the same app, after [previous] was lost: the peers
  /// and their keys are the same.
  ScriptedChannel.after(ScriptedChannel previous) {
    _peers.addAll(previous._peers);
  }

  final server = StreamController<Object?>();
  @override
  final RecordingSink sink = RecordingSink();

  void receive(Frame frame) => server.add(frame.encode());

  final Map<String, E2eSession> _peers = {};
  final Map<String, List<RelayedFrame>> _opened = {};

  /// The relay starts conversation [sid] with [peer], who sends its key.
  Future<void> startSession(String sid, String peer) async {
    final e2e = _peers[sid] = E2eSession(sid);
    receive(SessionStartedFrame(sid: sid, peer: peer));
    receive(await e2e.offer());
  }

  /// Takes the app's key for [sid] once it has been sent.
  Future<E2eSession> _ready(String sid) async {
    final e2e = _peers[sid]!;
    for (var i = 0; !e2e.isReady && i < 1000; i++) {
      final offer = sink.sent.whereType<KeyOfferFrame>().where(
        (f) => f.sid == sid,
      );
      if (offer.isNotEmpty) {
        await e2e.accept(offer.first);
      } else {
        await Future<void>.microtask(() {});
      }
    }
    return e2e;
  }

  /// The peer sends [frame], sealed as the app expects.
  Future<void> receiveSecure(RelayedFrame frame) async {
    final e2e = await _ready(frame.sid);
    receive(await e2e.seal(frame));
  }

  /// The safety code on the peer's side of [sid].
  Future<String?> peerSafetyCode(String sid) async =>
      (await _ready(sid)).safetyCode();

  /// Everything the app sent in [sid] so far, decrypted.
  Future<List<RelayedFrame>> openedSent(String sid) async {
    final e2e = await _ready(sid);
    final opened = _opened[sid] ??= [];
    final sealed = sink.sent.whereType<SealedFrame>().where(
      (f) => f.sid == sid,
    );
    for (final frame in sealed.skip(opened.length)) {
      opened.add(await e2e.open(frame));
    }
    return opened;
  }

  @override
  Future<void> get ready async {}

  @override
  Stream<Object?> get stream => server.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A handshake that never completes (blocked by a proxy, firewall…).
class HangingChannel implements WebSocketChannel {
  @override
  Future<void> get ready => Completer<void>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Microphone driven by the test.
class FakeVoiceRecorder implements VoiceRecorder {
  FakeVoiceRecorder({this.result, this.failure});

  /// What [stop] returns.
  RecordedVoice? result;

  /// Thrown by [start] (e.g. permission denied).
  VoiceRecorderException? failure;
  bool recording = false;
  int cancelled = 0;

  @override
  Duration maxDuration = const Duration(seconds: kMaxVoiceSeconds);

  @override
  Future<void> start() async {
    final failure = this.failure;
    if (failure != null) throw failure;
    recording = true;
  }

  @override
  Future<RecordedVoice?> stop() async {
    recording = false;
    return result;
  }

  @override
  Future<void> cancel() async {
    recording = false;
    cancelled++;
  }

  @override
  Future<void> dispose() async {}
}

/// Audio output that only records what it was asked to play.
class FakeAudioBackend implements AudioBackend {
  final played = <Uint8List>[];
  final _positions = StreamController<Duration>.broadcast();
  final _completions = StreamController<void>.broadcast();
  bool paused = false;

  void complete() => _completions.add(null);

  @override
  Future<void> play(Uint8List bytes, String mime) async => played.add(bytes);

  @override
  Future<void> pause() async => paused = true;

  @override
  Future<void> resume() async => paused = false;

  @override
  Future<void> stop() async {}

  @override
  Stream<Duration> get positions => _positions.stream;

  @override
  Stream<void> get completions => _completions.stream;

  @override
  Future<void> dispose() async {
    await _positions.close();
    await _completions.close();
  }
}

/// Clipboard driven by the test: [images] and [files] for Ctrl+V (Windows),
/// [paste] for the browser's paste.
class FakeClipboardImages implements ClipboardImages {
  List<Uint8List> images = [];
  List<ChosenFile> files = [];
  final _pasted = StreamController<Attachments>.broadcast();

  void paste(List<Uint8List> images, {List<ChosenFile> files = const []}) =>
      _pasted.add(Attachments(images: images, files: files));

  @override
  bool get readsOnPasteKey => true;

  @override
  Future<Attachments> read() async => Attachments(images: images, files: files);

  @override
  Stream<Attachments> get pasted => _pasted.stream;
}

/// A camera driven by the test.
class FakeLiveCamera implements LiveCamera {
  FakeLiveCamera({this.failure});

  /// Thrown by [open] (no camera, access refused…).
  LiveCameraException? failure;

  /// Thrown by [nextFrame] (the camera stopped).
  LiveCameraException? frameFailure;
  Uint8List frame = Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);
  bool opened = false;
  bool closed = false;
  final qualities = <int>[];
  final sides = <int>[];
  final captureSides = <int>[];

  /// Video codecs it encodes into (none: JPEG only).
  Set<String> codecs = {};
  final requests = <LiveFrameRequest>[];

  /// Video: the next frames are deltas unless a key frame is asked for (the
  /// first one always is, as with a new encoder).
  bool _started = false;
  int rotation = 0;
  Uint8List preview = Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);

  @override
  Future<void> open() async {
    final failure = this.failure;
    if (failure != null) throw failure;
    opened = true;
  }

  @override
  Future<Set<String>> encoders() async => codecs;

  @override
  Future<LiveCameraFrame?> nextFrame(LiveFrameRequest request) async {
    final failure = frameFailure;
    if (failure != null) throw failure;
    requests.add(request);
    qualities.add(request.quality);
    sides.add(request.side);
    if (request.codec == null) return LiveCameraFrame(frame);
    final key = request.key || !_started;
    _started = true;
    return LiveCameraFrame(
      frame,
      key: key,
      rotation: rotation,
      preview: request.preview ? preview : null,
    );
  }

  @override
  Future<void> setCaptureSide(int side) async => captureSides.add(side);

  @override
  Future<void> close() async => closed = true;
}

/// Webcam driven by the test.
class FakeCameraCapture implements CameraCapture {
  FakeCameraCapture({this.failure, Uint8List? photo})
    : photo = photo ?? Uint8List.fromList([0xff, 0xd8, 0xff]);

  /// Thrown by [open] (no webcam, access refused…).
  CameraCaptureException? failure;
  final Uint8List photo;
  bool opened = false;
  bool closed = false;

  @override
  double get aspectRatio => 4 / 3;

  @override
  Future<void> open() async {
    final failure = this.failure;
    if (failure != null) throw failure;
    opened = true;
  }

  @override
  Widget preview() =>
      const ColoredBox(key: Key('fake-preview'), color: Color(0xFF336699));

  @override
  Future<Uint8List> takePicture() async => photo;

  @override
  Future<void> close() async => closed = true;
}

/// A file "chosen" by the user, in memory.
class FakeChosenFile implements ChosenFile {
  FakeChosenFile(this.name, this.bytes, {int? size}) : _size = size;

  @override
  final String name;
  final Uint8List bytes;
  final int? _size;
  bool closed = false;
  final reads = <int>[];

  /// Throws when reading this offset (a file gone meanwhile).
  int? failAt;

  @override
  int get size => _size ?? bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    reads.add(offset);
    if (offset == failAt) {
      throw const FileStorageException('Fichier introuvable.');
    }
    return Uint8List.sublistView(bytes, offset, offset + length);
  }

  @override
  Future<void> close() async => closed = true;
}

/// Received files, kept in memory.
class MemoryFileStorage implements FileStorage {
  final sinks = <MemoryFileSink>[];

  /// Makes [create] fail (disk full, no Downloads folder…).
  String? createError;

  /// Makes the n-th write of every file fail.
  int? failWrite;

  @override
  Future<FileSink> create(String name, int size) async {
    if (createError != null) throw FileStorageException(createError!);
    final sink = MemoryFileSink(name, failWrite);
    sinks.add(sink);
    return sink;
  }
}

class MemoryFileSink implements FileSink {
  MemoryFileSink(this.name, this._failWrite);

  @override
  final String name;
  final int? _failWrite;
  final data = BytesBuilder();
  int writes = 0;
  bool closed = false;
  bool aborted = false;

  @override
  Future<void> write(Uint8List bytes) async {
    if (++writes == _failWrite) {
      throw const FileStorageException('Disque plein.');
    }
    data.add(bytes);
  }

  @override
  Future<SavedFile> close() async {
    closed = true;
    return FakeSavedFile(name);
  }

  @override
  Future<void> abort() async => aborted = true;
}

class FakeSavedFile implements SavedFile {
  FakeSavedFile(this.name);

  @override
  final String name;
  int opened = 0;
  int shown = 0;

  @override
  String get location => 'Téléchargements';

  @override
  bool get canOpen => true;

  @override
  bool get canShowInFolder => true;

  @override
  Future<bool> open() async {
    opened++;
    return true;
  }

  @override
  Future<bool> showInFolder() async {
    shown++;
    return true;
  }
}

/// Video decoders driven by the test: each decoded frame shows as a texture
/// (no image to create).
class FakeLiveVideo implements LiveVideoCodecs {
  FakeLiveVideo({Set<String>? codecs}) : codecs = codecs ?? {kLiveCodecH264};

  Set<String> codecs;
  final created = <FakeLiveVideoDecoder>[];

  @override
  Future<Set<String>> decoders() => SynchronousFuture(codecs);

  @override
  LiveVideoDecoder? create(String codec) {
    if (!codecs.contains(codec)) return null;
    final decoder = FakeLiveVideoDecoder(created.length + 1);
    created.add(decoder);
    return decoder;
  }
}

class FakeLiveVideoDecoder implements LiveVideoDecoder {
  FakeLiveVideoDecoder(this.texture);

  final int texture;
  final decoded = <({Uint8List data, bool key, int rotation})>[];
  bool closed = false;

  /// The next decode throws (a broken stream).
  bool failNext = false;

  /// Holds each decode until completed by the test, when set.
  Completer<void>? gate;

  @override
  Future<LivePicture?> decode(
    Uint8List data, {
    required bool key,
    required int rotation,
  }) async {
    await gate?.future;
    if (failNext) {
      failNext = false;
      throw StateError('broken');
    }
    decoded.add((data: data, key: key, rotation: rotation));
    return LivePicture.texture(
      texture,
      width: 640,
      height: 480,
      rotation: rotation,
    );
  }

  @override
  Future<void> close() async => closed = true;
}
