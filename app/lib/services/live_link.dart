import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';

import 'live_audio.dart';
import 'live_camera.dart';
import 'live_picture.dart';
import 'live_video.dart';

export 'live_picture.dart';

/// My view of the peer's camera.
enum LiveWatch {
  idle,

  /// Asked; the peer has not answered yet.
  requesting,

  /// The peer agreed: their frames are shown.
  watching,
}

/// My own camera, shared with the peer.
enum LiveShare {
  idle,

  /// The peer asked: waiting for my answer. The camera is still off.
  asked,

  /// I agreed; the camera is turning on.
  starting,

  /// The peer sees my camera.
  sharing,
}

/// Decodes a received JPEG frame; null if it cannot or must not be shown.
typedef LiveImageDecoder = Future<ui.Image?> Function(Uint8List jpeg);

/// The picture of a camera, which knows whether anyone is looking at it:
/// nothing is decoded for a conversation that is not on screen.
class LiveImage extends ValueNotifier<LivePicture?> {
  LiveImage() : super(null);

  bool get watched => hasListeners;

  /// Takes ownership of [picture].
  void show(LivePicture? picture) {
    final previous = value;
    if (previous == picture) return;
    value = picture;
    // Widgets hold their own handle (RawImage clones what it paints).
    if (!identical(previous?.image, picture?.image)) previous?.dispose();
  }

  @override
  void dispose() {
    value?.dispose();
    super.dispose();
  }
}

/// The peer's sound in my view of their camera.
class LiveSound extends ChangeNotifier {
  bool _available = false;
  bool _peerMuted = false;
  bool _on = true;

  /// The peer shares their microphone with their camera.
  bool get available => _available;

  /// The peer muted their microphone: nothing comes.
  bool get peerMuted => _peerMuted;

  /// Whether I listen (my own choice, back to yes with each view).
  bool get on => _on;

  void toggle() {
    _on = !_on;
    notifyListeners();
  }

  void _set({bool? available, bool? peerMuted, bool? on}) {
    final next = (available ?? _available, peerMuted ?? _peerMuted, on ?? _on);
    if (next == (_available, _peerMuted, _on)) return;
    _available = next.$1;
    _peerMuted = next.$2;
    _on = next.$3;
    notifyListeners();
  }
}

/// A received video frame waiting to be decoded.
typedef _Queued = ({
  int n,
  Uint8List data,
  bool key,
  int rotation,
  int? sentAt,
});

/// The live camera view of one conversation, in both directions.
///
/// The camera only ever turns on after [acceptRequest], called from a user's
/// action, each time: an agreement is never remembered, and the viewer can
/// neither start nor keep the camera on alone. Frames are ignored unless they
/// were asked for and agreed to.
///
/// Frames are video (H.264) when the viewer can decode it and the owner's
/// camera can encode it, JPEG otherwise: an older version on either side
/// still sees JPEG.
class LiveLink extends ChangeNotifier {
  LiveLink({
    required this.sid,
    required void Function(RelayedFrame frame) send,
    LiveCamera? Function()? createCamera,
    LiveMicrophone? Function()? createMicrophone,
    LiveSpeaker? Function()? createSpeaker,
    LiveImageDecoder? decode,
    LiveVideoCodecs? video,
    int Function()? clock,
  }) : _send = send,
       _createCamera = createCamera ?? platformLiveCamera,
       _createMicrophone = createMicrophone ?? platformLiveMicrophone,
       _createSpeaker = createSpeaker ?? platformLiveSpeaker,
       _decode = decode ?? decodeLiveFrame,
       _video = video ?? platformLiveVideo(),
       _clock = clock ?? _stopwatchClock();

  final String sid;
  final void Function(RelayedFrame frame) _send;
  final LiveCamera? Function() _createCamera;
  final LiveMicrophone? Function() _createMicrophone;
  final LiveSpeaker? Function() _createSpeaker;
  final LiveImageDecoder _decode;
  final LiveVideoCodecs _video;
  final int Function() _clock;

  static int Function() _stopwatchClock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsedMilliseconds;
  }

  final _notices = StreamController<String>.broadcast();
  bool _closed = false;

  /// What the user should be told (a refusal, a camera error…), in French.
  Stream<String> get notices => _notices.stream;

  // Viewer side.

  LiveWatch _watch = LiveWatch.idle;
  LiveWatch get watch => _watch;

  /// The last frame of the peer's camera.
  final LiveImage image = LiveImage();

  /// Images shown so far, each one (a texture keeps its picture while its
  /// image changes): for `check_windows_camera`.
  final ValueNotifier<int> shown = ValueNotifier(0);
  Timer? _requestTimer;
  int _lastFrame = 0;
  int? _pendingFrame;
  Uint8List? _pendingJpeg;
  int? _pendingAt;
  bool _decoding = false;
  LivePacer _pacer = LivePacer();

  /// Decoded frames waiting for their turn, with when to show them.
  final List<(LivePicture, int)> _held = [];
  Timer? _holdTimer;

  /// Codecs offered in my request, and the one the owner chose (null: JPEG).
  List<String> _offered = const [];
  String? _codec;

  /// The video codec of the frames shown, null for JPEG.
  String? get codec => _codec;
  LiveVideoDecoder? _decoder;

  /// The peer's sound: what plays it (from my request on), its codec once
  /// agreed, the playout buffer.
  final LiveSound sound = LiveSound();
  LiveSpeaker? _speaker;
  bool _speakerOpen = false;
  String? _audioCodec;
  int _lastAudio = 0;
  final _jitter = LiveAudioJitter();
  final List<_Queued> _queue = [];
  bool _needKey = true;
  int? _keyAskedAt;

  /// Asks to see the peer's camera.
  void request() {
    if (_closed || _watch != LiveWatch.idle) return;
    _setWatch(LiveWatch.requesting);
    _sendRequest();
    _requestTimer = Timer(
      const Duration(seconds: kLiveRequestTimeoutSeconds),
      () {
        if (_watch != LiveWatch.requesting) return;
        stopWatching();
        _tell('Pas de réponse à votre demande de caméra.');
      },
    );
  }

  /// With the video codecs this device decodes: the owner picks one if its
  /// camera can encode it. At once when they are known already (a
  /// [SynchronousFuture]).
  void _sendRequest() {
    // Sound only if this device can play it.
    _speaker ??= _createSpeaker();
    final audio = _speaker == null ? const <String>[] : [kLiveAudioAdpcm];
    void send(Set<String> codecs) {
      if (_closed || _watch != LiveWatch.requesting) return;
      _offered = [
        for (final codec in codecs)
          if (codec == kLiveCodecH264) codec,
      ];
      _send(LiveRequestFrame(sid: sid, codecs: _offered, audio: audio));
    }

    Future<Set<String>> codecs;
    try {
      codecs = _video.decoders();
    } catch (_) {
      codecs = SynchronousFuture(const {});
    }
    codecs.then(send, onError: (Object _) => send(const {}));
  }

  /// The view goes to full screen, or comes back: the peer's camera follows,
  /// as far as the network allows.
  void setFullView(bool full) {
    if (_closed || _watch != LiveWatch.watching) return;
    _send(LiveSizeFrame(sid: sid, side: full ? kLiveFullSide : kLiveMaxSide));
  }

  /// Withdraws the request, or closes the view: the peer's camera goes off.
  void stopWatching() {
    if (_closed || _watch == LiveWatch.idle) return;
    _send(LiveStopFrame(sid: sid));
    _endWatch();
  }

  void _endWatch() {
    _requestTimer?.cancel();
    _requestTimer = null;
    _pendingJpeg = null;
    _pendingFrame = null;
    _pendingAt = null;
    _lastFrame = 0;
    _pacer = LivePacer();
    _queue.clear();
    _codec = null;
    _offered = const [];
    _needKey = true;
    _keyAskedAt = null;
    _closeDecoder();
    _dropHeld();
    _closeSpeaker();
    image.show(null);
    _setWatch(LiveWatch.idle);
  }

  void _closeSpeaker() {
    final speaker = _speaker;
    _speaker = null;
    _speakerOpen = false;
    _audioCodec = null;
    _lastAudio = 0;
    _jitter.reset();
    sound._set(available: false, peerMuted: false, on: true);
    if (speaker != null) unawaited(speaker.close().catchError((_) {}));
  }

  Future<void> _openSpeaker(LiveSpeaker speaker) async {
    try {
      await speaker.open();
    } catch (_) {
      if (_speaker == speaker) {
        _tell('Impossible de jouer le son sur cet appareil.');
        _audioCodec = null;
        sound._set(available: false);
      }
      return;
    }
    if (_speaker != speaker || _closed) {
      await speaker.close().catchError((_) {});
      return;
    }
    _speakerOpen = true;
  }

  void _receiveAudio(int n, String data) {
    if (_audioCodec != kLiveAudioAdpcm || n <= _lastAudio) return;
    _lastAudio = n;
    final speaker = _speaker;
    if (speaker == null || !_speakerOpen || !sound.on) return;
    final Int16List? samples;
    try {
      samples = ImaAdpcm.decode(base64Decode(data));
    } on FormatException {
      return;
    }
    if (samples == null) return;
    for (final chunk in _jitter.push(samples, _clock())) {
      speaker.play(chunk);
    }
  }

  void _closeDecoder() {
    final decoder = _decoder;
    _decoder = null;
    if (decoder != null) unawaited(decoder.close().catchError((_) {}));
  }

  void _dropHeld() {
    _holdTimer?.cancel();
    _holdTimer = null;
    for (final (picture, _) in _held) {
      picture.dispose();
    }
    _held.clear();
  }

  /// Shows [picture] when its turn comes, to keep a steady pace.
  void _present(LivePicture picture, int? sentAt) {
    if (picture.image == null) {
      // A texture is drawn by its decoder as soon as decoded.
      image.show(picture);
      shown.value++;
      return;
    }
    final now = _clock();
    final hold = sentAt == null ? 0 : _pacer.holdFor(sentAt, now);
    _held.add((picture, now + hold));
    // Too far behind: the oldest give way.
    while (_held.length > kLiveMaxHeldFrames) {
      _held.removeAt(0).$1.dispose();
    }
    _showDue();
  }

  /// Shows what is due (the latest if several are: the screen only shows one),
  /// then waits for the next.
  void _showDue() {
    _holdTimer?.cancel();
    _holdTimer = null;
    final now = _clock();
    LivePicture? due;
    while (_held.isNotEmpty && _held.first.$2 <= now) {
      due?.dispose();
      due = _held.removeAt(0).$1;
    }
    if (due != null) {
      image.show(due);
      shown.value++;
    }
    if (_held.isEmpty) return;
    _holdTimer = Timer(Duration(milliseconds: _held.first.$2 - now), _showDue);
  }

  void _setWatch(LiveWatch next) {
    if (_watch == next) return;
    _watch = next;
    notifyListeners();
  }

  /// JPEG: only the latest frame matters. One being decoded makes the next
  /// ones wait, and a newer one replaces them. The acknowledgement says up to
  /// where the camera owner may go on.
  Future<void> _decodePending() async {
    if (_decoding) return;
    _decoding = true;
    try {
      while (_pendingJpeg != null && !_closed) {
        final jpeg = _pendingJpeg!;
        final frame = _pendingFrame!;
        final sentAt = _pendingAt;
        _pendingJpeg = null;
        if (image.watched) {
          ui.Image? decoded;
          try {
            decoded = await _decode(jpeg);
          } catch (_) {
            // A broken frame: the next one will do.
          }
          if (_closed || _watch != LiveWatch.watching) {
            decoded?.dispose();
            return;
          }
          if (decoded != null) _present(LivePicture.image(decoded), sentAt);
        }
        if (_watch == LiveWatch.watching) {
          _send(LiveAckFrame(sid: sid, n: frame));
        }
      }
    } finally {
      _decoding = false;
    }
  }

  /// Video: frames need the ones before them. Each is decoded in order; one
  /// that cannot be (the view was hidden, a broken frame, too far behind)
  /// makes the next ones wait for a key frame, which is asked for.
  void _receiveVideo(_Queued frame) {
    if (!image.watched) {
      // Nothing decoded off screen: the view will start from a key frame.
      _needKey = true;
      _queue.clear();
      _send(LiveAckFrame(sid: sid, n: frame.n));
      return;
    }
    if (frame.key) _needKey = false;
    if (_needKey) {
      _askKey();
      _send(LiveAckFrame(sid: sid, n: frame.n));
      return;
    }
    _queue.add(frame);
    if (_queue.length > kLiveMaxQueuedFrames) {
      // Decoding cannot keep up: start again from a key frame.
      _queue.clear();
      _restartVideo();
      _send(LiveAckFrame(sid: sid, n: frame.n));
      return;
    }
    unawaited(_decodeVideo());
  }

  bool _decodingVideo = false;

  Future<void> _decodeVideo() async {
    if (_decodingVideo) return;
    _decodingVideo = true;
    try {
      while (_queue.isNotEmpty && !_closed) {
        final frame = _queue.removeAt(0);
        final codec = _codec;
        if (codec == null || _watch != LiveWatch.watching) return;
        final decoder = _decoder ??= _video.create(codec);
        if (decoder == null) {
          stopWatching();
          _tell('Impossible d’afficher la vidéo sur cet appareil.');
          return;
        }
        LivePicture? picture;
        try {
          picture = await decoder.decode(
            frame.data,
            key: frame.key,
            rotation: frame.rotation,
          );
        } catch (_) {
          if (_decoder == decoder) _restartVideo();
        }
        if (_closed || _watch != LiveWatch.watching) {
          picture?.dispose();
          return;
        }
        _send(LiveAckFrame(sid: sid, n: frame.n));
        if (_decoder != decoder) {
          // Restarted meanwhile: wait for the key frame.
          picture?.dispose();
          continue;
        }
        if (picture != null) _present(picture, frame.sentAt);
      }
    } finally {
      _decodingVideo = false;
    }
  }

  /// A new decoder, from the next key frame.
  void _restartVideo() {
    _closeDecoder();
    _queue.clear();
    _needKey = true;
    _askKey();
  }

  void _askKey() {
    final now = _clock();
    final asked = _keyAskedAt;
    if (asked != null && now - asked < kLiveKeyRequestMs) return;
    _keyAskedAt = now;
    _send(LiveKeyFrame(sid: sid));
  }

  // Camera owner side.

  LiveShare _share = LiveShare.idle;
  LiveShare get share => _share;

  /// What the peer sees of my camera, now and then.
  final LiveImage ownImage = LiveImage();
  LiveCamera? _camera;
  LiveFlow? _flow;

  /// My microphone, shared with the camera when the viewer can play it and
  /// I allow it.
  LiveMicrophone? _microphone;
  String? _sharedAudio;
  List<String> _peerAudio = const [];
  final _packer = LiveAudioPacker();
  int _audioSent = 0;
  bool _micMuted = false;

  /// The viewer can hear my microphone, if I allow it.
  bool get asksMicrophone => _peerAudio.contains(kLiveAudioAdpcm);

  /// The sound codec my microphone sends in, null when it is not shared.
  String? get sharedAudio => _sharedAudio;

  /// My microphone is shared but muted: nothing leaves.
  bool get micMuted => _micMuted;

  /// Mutes my microphone, or unmutes it. The viewer is told.
  void setMicMuted(bool muted) {
    if (_closed || _sharedAudio == null || _micMuted == muted) return;
    _micMuted = muted;
    _packer.reset();
    _send(LiveMuteFrame(sid: sid, muted: muted));
    notifyListeners();
  }

  void _onPcm(int run, Uint8List pcm) {
    if (run != _shareRun || _sharedAudio == null || _micMuted || _closed) {
      return;
    }
    for (final packet in _packer.add(pcm)) {
      _send(
        LiveAudioFrame(sid: sid, n: ++_audioSent, data: base64Encode(packet)),
      );
    }
  }

  /// Video codecs the viewer offered, and the one I send in (null: JPEG).
  List<String> _peerCodecs = const [];
  String? _sharedCodec;

  /// The codec my camera sends in, null for JPEG.
  String? get sharedCodec => _sharedCodec;
  bool _wantKey = false;

  /// Changes whenever the camera is stopped: a loop still running sees it.
  int _shareRun = 0;
  int? _declinedAt;
  Timer? _sleepTimer;
  Completer<void>? _sleep;

  /// While sharing: what the network looks like, for `check_windows_camera`.
  LiveFlow? get flow => _flow;

  /// Agrees to the peer's request: the camera turns on, and the microphone
  /// too when the viewer can hear it, unless [microphone] is false.
  Future<void> acceptRequest({bool microphone = true}) async {
    if (_closed || _share != LiveShare.asked) return;
    final run = ++_shareRun;
    _setShare(LiveShare.starting);
    final camera = _camera = _createCamera();
    if (camera == null) {
      return _failShare('Aucune caméra sur cet appareil.');
    }
    String? codec;
    try {
      await camera.open();
      if (run == _shareRun && _peerCodecs.isNotEmpty) {
        final encoders = await camera.encoders();
        codec = _peerCodecs.where(encoders.contains).firstOrNull;
      }
    } catch (e) {
      if (run == _shareRun) _failShare(_describe(e));
      return;
    }
    if (run != _shareRun) {
      // Stopped while it was turning on.
      await camera.close();
      return;
    }
    final audio = microphone && asksMicrophone
        ? await _openMicrophone(run)
        : null;
    if (run != _shareRun) return;
    _sharedAudio = audio;
    _sharedCodec = codec;
    final flow = _flow = LiveFlow(video: codec != null);
    // Video affords a larger small view.
    if (codec != null) unawaited(camera.setCaptureSide(flow.smallSide));
    _setShare(LiveShare.sharing);
    _send(LiveAcceptFrame(sid: sid, codec: codec, audio: audio));
    await _shareLoop(run, camera, flow);
  }

  /// Turns my microphone on for the view: its codec, or null when it cannot
  /// be (the camera is then shared without sound, and I am told).
  Future<String?> _openMicrophone(int run) async {
    final microphone = _microphone = _createMicrophone();
    if (microphone == null) {
      _tell('Aucun micro utilisable : la caméra est partagée sans le son.');
      return null;
    }
    try {
      await microphone.open((pcm) => _onPcm(run, pcm));
    } catch (e) {
      if (_microphone == microphone) _microphone = null;
      if (run == _shareRun) {
        _tell(
          e is LiveAudioException
              ? e.message
              : 'Micro indisponible : la caméra est partagée sans le son.',
        );
      }
      return null;
    }
    if (run != _shareRun) {
      // Stopped while it was turning on.
      await _closeMicrophone(microphone);
      return null;
    }
    return kLiveAudioAdpcm;
  }

  /// Refuses the peer's request.
  void declineRequest() {
    if (_closed || _share != LiveShare.asked) return;
    _declinedAt = _clock();
    _send(LiveEndFrame(sid: sid, reason: LiveEndReason.declined));
    _setShare(LiveShare.idle);
  }

  /// Stops showing my camera to the peer: it goes off at once.
  void stopSharing() {
    if (_closed) return;
    if (_share == LiveShare.asked) return declineRequest();
    if (_share == LiveShare.idle) return;
    _send(LiveEndFrame(sid: sid, reason: LiveEndReason.stopped));
    _turnOff();
  }

  void _failShare(String message) {
    _send(LiveEndFrame(sid: sid, reason: LiveEndReason.unavailable));
    _turnOff();
    _tell(message);
  }

  void _turnOff() {
    _shareRun++;
    final camera = _camera;
    _camera = null;
    _flow = null;
    _sharedCodec = null;
    _wantKey = false;
    final microphone = _microphone;
    _microphone = null;
    _sharedAudio = null;
    _micMuted = false;
    _packer.reset();
    _audioSent = 0;
    _wake();
    ownImage.show(null);
    _setShare(LiveShare.idle);
    unawaited(_closeCamera(camera));
    unawaited(_closeMicrophone(microphone));
  }

  static Future<void> _closeMicrophone(LiveMicrophone? microphone) async {
    try {
      await microphone?.close();
    } catch (_) {
      // It is off, or gone.
    }
  }

  static Future<void> _closeCamera(LiveCamera? camera) async {
    try {
      await camera?.close();
    } catch (_) {
      // It is off, or gone.
    }
  }

  void _setShare(LiveShare next) {
    if (_share == next) return;
    _share = next;
    notifyListeners();
  }

  /// When nothing can be done yet: about one image of the target rate.
  static const _retryMs = 1000 ~/ kLiveTargetFps;

  Future<void> _shareLoop(int run, LiveCamera camera, LiveFlow flow) async {
    final codec = _sharedCodec;
    // A new encoder starts with a key frame; asking costs nothing.
    _wantKey = codec != null;
    var count = 0;
    while (run == _shareRun) {
      if (!flow.canSend(_clock())) {
        // An acknowledgement wakes this up as soon as a frame can leave.
        await _sleepFor(_retryMs);
        continue;
      }
      final LiveCameraFrame? frame;
      try {
        frame = await camera
            .nextFrame(
              LiveFrameRequest(
                side: flow.side,
                quality: flow.quality,
                codec: codec,
                kbps: flow.kbps,
                key: _wantKey,
                // The small preview does not need every frame.
                preview: codec != null && count % 8 == 0 && ownImage.watched,
              ),
            )
            .timeout(const Duration(seconds: kLiveCameraTimeoutSeconds));
      } catch (e) {
        if (run == _shareRun) _failShare(_describe(e));
        return;
      }
      if (run != _shareRun) return;
      if (frame == null || frame.data.isEmpty) {
        await _sleepFor(_retryMs);
        continue;
      }
      if (frame.data.length > kMaxLiveFrameBytes) {
        flow.tooLarge();
        // Video: the next frames would need this one.
        if (codec != null) _wantKey = true;
        // Not at once: this would never give the app a chance to run.
        await _sleepFor(_retryMs);
        continue;
      }
      if (frame.key) _wantKey = false;
      final now = _clock();
      _send(
        LiveVideoFrame(
          sid: sid,
          n: flow.sent(now),
          data: base64Encode(frame.data),
          sentAt: now,
          key: codec != null && frame.key,
          rotation: codec != null ? frame.rotation : 0,
        ),
      );
      if (codec == null) {
        if (count % 4 == 0 && ownImage.watched) {
          unawaited(_showOwn(run, frame.data, 0));
        }
      } else if (frame.preview case final preview?) {
        unawaited(_showOwn(run, preview, frame.rotation));
      }
      count++;
    }
  }

  Future<void> _showOwn(int run, Uint8List jpeg, int rotation) async {
    ui.Image? decoded;
    try {
      decoded = await _decode(jpeg);
    } catch (_) {
      return;
    }
    if (decoded == null) return;
    if (run != _shareRun || _closed) {
      decoded.dispose();
      return;
    }
    ownImage.show(LivePicture.image(decoded, rotation: rotation));
  }

  Future<void> _sleepFor(int ms) {
    final sleep = _sleep = Completer<void>();
    _sleepTimer?.cancel();
    _sleepTimer = Timer(Duration(milliseconds: ms), _wake);
    return sleep.future;
  }

  void _wake() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    final sleep = _sleep;
    _sleep = null;
    if (sleep != null && !sleep.isCompleted) sleep.complete();
  }

  static String _describe(Object error) => error is LiveCameraException
      ? error.message
      : 'Caméra inaccessible (${error.toString().split('\n').first}).';

  // Both sides.

  void receive(RelayedFrame frame) {
    if (_closed) return;
    switch (frame) {
      case LiveRequestFrame(:final codecs, :final audio):
        if (_share != LiveShare.idle) return;
        final declined = _declinedAt;
        if (declined != null &&
            _clock() - declined < kLiveDeclineCooldownSeconds * 1000) {
          _send(LiveEndFrame(sid: sid, reason: LiveEndReason.declined));
          return;
        }
        _peerCodecs = codecs;
        _peerAudio = audio;
        _setShare(LiveShare.asked);
      case LiveStopFrame():
        // The request is withdrawn, or the view closed.
        if (_share == LiveShare.asked) {
          _setShare(LiveShare.idle);
        } else if (_share != LiveShare.idle) {
          _turnOff();
        }
      case LiveAcceptFrame(:final codec, :final audio):
        if (_watch != LiveWatch.requesting) return;
        _requestTimer?.cancel();
        _requestTimer = null;
        if (codec != null && !_offered.contains(codec)) {
          // Not what was offered: nothing could be shown.
          stopWatching();
          _tell('Format vidéo inconnu : mettez Dismessage à jour.');
          return;
        }
        _codec = codec;
        _needKey = true;
        final speaker = _speaker;
        if (audio == kLiveAudioAdpcm && speaker != null) {
          _audioCodec = audio;
          sound._set(available: true);
          unawaited(_openSpeaker(speaker));
        }
        _setWatch(LiveWatch.watching);
      case LiveEndFrame(:final reason):
        if (_watch == LiveWatch.idle) return;
        final message = switch (reason) {
          LiveEndReason.declined => 'Votre demande de caméra a été refusée.',
          LiveEndReason.unavailable => 'Sa caméra est indisponible.',
          _ => 'La caméra a été coupée.',
        };
        _endWatch();
        _tell(message);
      case LiveSizeFrame(:final side):
        final flow = _flow;
        if (flow == null) return;
        flow.maxSide = side.clamp(kLiveMaxSide, kLiveFullSide);
        unawaited(_camera?.setCaptureSide(flow.maxSide));
      case LiveKeyFrame():
        if (_flow != null && _sharedCodec != null) _wantKey = true;
      case LiveVideoFrame(
        :final n,
        :final data,
        :final sentAt,
        :final key,
        :final rotation,
      ):
        // Only what was asked for and agreed to.
        if (_watch != LiveWatch.watching || n <= _lastFrame) return;
        final Uint8List bytes;
        try {
          bytes = base64Decode(data);
        } on FormatException {
          return;
        }
        _lastFrame = n;
        if (_codec != null) {
          return _receiveVideo((
            n: n,
            data: bytes,
            key: key,
            rotation: rotation,
            sentAt: sentAt,
          ));
        }
        _pendingFrame = n;
        _pendingJpeg = bytes;
        _pendingAt = sentAt;
        unawaited(_decodePending());
      case LiveAudioFrame(:final n, :final data):
        if (_watch == LiveWatch.watching) _receiveAudio(n, data);
      case LiveMuteFrame(:final muted):
        if (_watch != LiveWatch.watching || _audioCodec == null) return;
        sound._set(peerMuted: muted);
        // What was gathered plays out.
        final speaker = _speaker;
        final gathered = _jitter.flush(_clock());
        if (speaker == null || !_speakerOpen || !sound.on) return;
        gathered.forEach(speaker.play);
      case LiveAckFrame(:final n):
        final flow = _flow;
        if (flow == null) return;
        if (flow.ack(n, _clock())) _wake();
      default:
        break;
    }
  }

  void _tell(String message) {
    if (!_closed) _notices.add(message);
  }

  /// The app is hidden (minimized, background): my camera stops, since I can
  /// no longer see that it is on.
  void onAppHidden() {
    if (_share == LiveShare.sharing || _share == LiveShare.starting) {
      stopSharing();
    }
  }

  /// The conversation ended: everything stops, nothing can be sent anymore.
  void onPeerLeft() {
    if (_closed) return;
    _requestTimer?.cancel();
    _requestTimer = null;
    _pendingJpeg = null;
    if (_share != LiveShare.idle) _turnOff();
    if (_watch != LiveWatch.idle) _endWatch();
  }

  @override
  void dispose() {
    onPeerLeft();
    _closed = true;
    _notices.close();
    image.dispose();
    sound.dispose();
    shown.dispose();
    ownImage.dispose();
    super.dispose();
  }
}

/// Decodes a JPEG received from the peer, after checking its announced size:
/// a tiny frame could otherwise ask for gigabytes of memory.
Future<ui.Image?> decodeLiveFrame(Uint8List jpeg) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(jpeg);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width > kLiveMaxDecodedSide ||
        descriptor.height > kLiveMaxDecodedSide) {
      return null;
    }
    codec = await descriptor.instantiateCodec();
    return (await codec.getNextFrame()).image;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}
