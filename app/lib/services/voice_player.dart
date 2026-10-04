import 'dart:async';

import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'chat_session.dart';

/// Low-level audio output, replaced by a fake in widget tests.
abstract class AudioBackend {
  Future<void> play(Uint8List bytes, String mime);
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Stream<Duration> get positions;
  Stream<void> get completions;
  Future<void> dispose();
}

/// The audio output of the current platform.
AudioBackend platformAudioBackend() =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android
    ? AndroidAudioBackend()
    : PluginAudioBackend();

/// Reports the playback position every 200 ms while playing.
abstract class _PollingBackend implements AudioBackend {
  final _positions = StreamController<Duration>.broadcast();
  final _completions = StreamController<void>.broadcast();
  Timer? _poll;

  Future<int?> currentPositionMs();

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 200), (_) async {
      final ms = await currentPositionMs();
      if (ms != null && !_positions.isClosed) {
        _positions.add(Duration(milliseconds: ms));
      }
    });
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  void _completed() {
    _stopPolling();
    if (!_completions.isClosed) _completions.add(null);
  }

  @override
  Stream<Duration> get positions => _positions.stream;

  @override
  Stream<void> get completions => _completions.stream;

  Future<void> _close() async {
    _stopPolling();
    await _positions.close();
    await _completions.close();
  }
}

/// Android: MediaPlayer through our own channel (see `VoiceHandler.kt`).
class AndroidAudioBackend extends _PollingBackend {
  AndroidAudioBackend() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onComplete') _completed();
    });
  }

  static const _channel = MethodChannel('dismessage/voice');

  @override
  Future<int?> currentPositionMs() => _channel.invokeMethod<int>('position');

  @override
  Future<void> play(Uint8List bytes, String mime) async {
    await _channel.invokeMethod<void>('play', {'bytes': bytes});
    _startPolling();
  }

  @override
  Future<void> pause() async {
    _stopPolling();
    await _channel.invokeMethod<void>('pause');
  }

  @override
  Future<void> resume() async {
    await _channel.invokeMethod<void>('resume');
    _startPolling();
  }

  @override
  Future<void> stop() async {
    _stopPolling();
    await _channel.invokeMethod<void>('stopPlayback');
  }

  @override
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await stop();
    await _close();
  }
}

/// Web and Windows: the `audioplayers` implementations, used directly.
class PluginAudioBackend extends _PollingBackend {
  static int _count = 0;
  final _id = 'dismessage-player-${_count++}';
  Future<void>? _created;
  StreamSubscription<AudioEvent>? _events;
  Completer<void>? _prepared;

  AudioplayersPlatformInterface get _platform =>
      AudioplayersPlatformInterface.instance;

  Future<void> _ensureCreated() => _created ??= () async {
    await _platform.create(_id);
    _events = _platform
        .getEventStream(_id)
        .listen(
          (event) {
            switch (event.eventType) {
              case AudioEventType.complete:
                _completed();
              case AudioEventType.prepared when event.isPrepared == true:
                final prepared = _prepared;
                if (prepared != null && !prepared.isCompleted) {
                  prepared.complete();
                }
              default:
                break;
            }
          },
          onError: (Object e) {
            final prepared = _prepared;
            if (prepared != null && !prepared.isCompleted) {
              prepared.completeError(e);
            }
          },
        );
  }();

  @override
  Future<int?> currentPositionMs() => _platform.getCurrentPosition(_id);

  @override
  Future<void> play(Uint8List bytes, String mime) async {
    await _ensureCreated();
    // Some platforms load the source in the background: wait until ready.
    final prepared = _prepared = Completer<void>();
    await _platform.setSourceBytes(_id, bytes, mimeType: mime);
    await prepared.future.timeout(const Duration(seconds: 10));
    await _platform.resume(_id);
    _startPolling();
  }

  @override
  Future<void> pause() async {
    _stopPolling();
    await _platform.pause(_id);
  }

  @override
  Future<void> resume() async {
    await _platform.resume(_id);
    _startPolling();
  }

  @override
  Future<void> stop() async {
    _stopPolling();
    if (_created != null) await _platform.stop(_id);
  }

  @override
  Future<void> dispose() async {
    await _events?.cancel();
    if (_created != null) await _platform.dispose(_id);
    await _close();
  }
}

/// Plays the voice messages of a conversation, one at a time.
class VoicePlayer extends ChangeNotifier {
  /// The backend is only created on the first playback.
  VoicePlayer([AudioBackend Function()? createBackend])
    : _createBackend = createBackend ?? platformAudioBackend;

  final AudioBackend Function() _createBackend;
  AudioBackend? _backendOrNull;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  AudioBackend get _backend => _backendOrNull ??= _attach(_createBackend());

  AudioBackend _attach(AudioBackend backend) {
    _subscriptions.addAll([
      backend.positions.listen((p) {
        _position = p;
        notifyListeners();
      }),
      backend.completions.listen((_) {
        _playing = false;
        _currentId = null;
        _position = Duration.zero;
        notifyListeners();
      }),
    ]);
    return backend;
  }

  String? _currentId;
  bool _playing = false;
  Duration _position = Duration.zero;
  String? _error;

  /// Voice being played or paused.
  String? get currentId => _currentId;

  bool isPlaying(ChatVoice voice) => _playing && _currentId == voice.id;

  /// Playback position of [voice] (zero when it is not the current one).
  Duration positionOf(ChatVoice voice) =>
      _currentId == voice.id ? _position : Duration.zero;

  /// Why the last playback failed, if it did.
  String? get error => _error;

  /// Plays [voice], pauses it, or resumes it.
  Future<void> toggle(ChatVoice voice) async {
    _error = null;
    try {
      if (_currentId == voice.id) {
        _playing ? await _backend.pause() : await _backend.resume();
        _playing = !_playing;
      } else {
        await _backend.stop();
        _currentId = voice.id;
        _position = Duration.zero;
        _playing = true;
        notifyListeners();
        await _backend.play(voice.bytes, voice.mime);
      }
    } catch (_) {
      _playing = false;
      _currentId = null;
      _error = 'Lecture impossible sur cet appareil.';
    }
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _backendOrNull?.dispose();
    super.dispose();
  }
}
