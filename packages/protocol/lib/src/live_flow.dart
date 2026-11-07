import 'constants.dart';

/// Camera owner side of a live view: whether the next frame may leave, at which
/// size and JPEG quality.
///
/// Latency comes first. At most [window] frames travel at once: on a slow
/// network frames are skipped instead of piling up in the sockets and the
/// relay. As in video calls, the view adapts to keep its rate, from
/// the delay above the lowest measured (frames queueing somewhere): too heavy,
/// the size goes down, then the quality; room to spare, the quality goes up,
/// then the size, up to [maxSide].
///
/// There is no timer between frames: the camera gives the pace, each frame
/// being the next image it delivers. A timer would make things worse: one of
/// 25 ms lasts 31 ms on Windows, which then misses every other image of a
/// 30 images per second camera.
///
/// Times are milliseconds from any fixed origin, given by the caller.
class LiveFlow {
  final Map<int, int> _inFlight = {};
  int _next = 1;
  int? _lastAdjustAt;
  int? _lowestRtt;
  int? _lastRtt;
  int _quality = kLiveQualityStart;
  int _maxSide = kLiveMaxSide;
  int _side = kLiveMaxSide;

  /// JPEG quality of the next frame.
  int get quality => _quality;

  /// Longest side of the next frame.
  int get side => _side;

  /// Frames sent and not acknowledged yet.
  int get inFlight => _inFlight.length;

  /// Longest side the viewer can use: more in full screen.
  int get maxSide => _maxSide;
  set maxSide(int value) {
    if (value == _maxSide) return;
    _maxSide = value;
    _side = value > kLiveMaxSide
        ? (value < kLiveFullStartSide ? value : kLiveFullStartSide)
        : value;
  }

  /// Lowest delay measured between a frame and its acknowledgement, in
  /// milliseconds: the distance, without any queue.
  int? get lowestRtt => _lowestRtt;

  /// Last delay measured.
  int? get lastRtt => _lastRtt;

  /// Frames that may travel at once: what [kLiveTargetFps] puts on the way
  /// during [lowestRtt], with a margin for a relay that delivers in bursts. A
  /// fixed number would send bursts separated by gaps on a distant relay; this
  /// keeps a steady flow, and frames queueing are skipped all the same.
  int get window {
    final lowest = _lowestRtt ?? 0;
    final inTransit = (kLiveTargetFps * lowest * 1.5 / 1000).ceil() + 2;
    return inTransit.clamp(kLiveWindowFrames, kLiveMaxWindowFrames);
  }

  /// Whether a frame may leave; if not, an acknowledgement will free the
  /// window.
  bool canSend(int now) {
    if (_inFlight.length < window) return true;
    final oldest = _inFlight.values.reduce((a, b) => a < b ? a : b);
    if (now - oldest < kLiveStallMs) return false;
    // A stalled network: give up on these, and try with a light frame.
    _inFlight.clear();
    _quality = kLiveQualityMin;
    _side = kLiveMaxSide;
    _lastAdjustAt = now;
    return true;
  }

  /// A frame leaves now; returns its number.
  int sent(int now) {
    final n = _next++;
    _inFlight[n] = now;
    return n;
  }

  /// Frames up to [n] were handled by the viewer. Returns false for a frame
  /// that was never sent.
  bool ack(int n, int now) {
    if (n >= _next) return false;
    final sentAt = _inFlight[n];
    _inFlight.removeWhere((frame, _) => frame <= n);
    if (sentAt != null) _adapt(now - sentAt, now);
    return true;
  }

  /// The camera gave a frame too large to send: lighter next time.
  void tooLarge() {
    if (!_stepSideDown()) _quality = _clamp(_quality - 10);
  }

  /// At most twice per second: one slow frame says little.
  void _adapt(int rtt, int now) {
    _lastRtt = rtt;
    final lowest = _lowestRtt;
    if (lowest == null || rtt < lowest) _lowestRtt = rtt;
    final base = _lowestRtt!;
    final last = _lastAdjustAt;
    if (last != null && now - last < 500) return;
    // Only what comes on top of the distance: a far relay is not a slow one.
    if (rtt > base + kLiveQueueDelayMs) {
      if (!_stepSideDown()) _quality = _clamp(_quality - 8);
    } else if (rtt < base + kLiveClearDelayMs) {
      if (_quality < kLiveQualityMax) {
        _quality = _clamp(_quality + 3);
      } else {
        _stepSideUp();
      }
    } else {
      return;
    }
    _lastAdjustAt = now;
  }

  bool _stepSideDown() {
    final lower = kLiveSideSteps.lastWhere(
      (step) => step < _side,
      orElse: () => _side,
    );
    if (lower == _side) return false;
    _side = lower;
    return true;
  }

  void _stepSideUp() {
    final higher = kLiveSideSteps.firstWhere(
      (step) => step > _side,
      orElse: () => _side,
    );
    if (higher <= _maxSide) _side = higher;
  }

  static int _clamp(int quality) =>
      quality.clamp(kLiveQualityMin, kLiveQualityMax);
}

/// Viewer side: how long to hold a frame so that images come at a steady pace,
/// despite a network that delivers them in bursts. Only as long as the measured
/// irregularity asks for, at most [kLiveMaxBufferMs].
///
/// The two clocks differ: only variations of the transit time count.
class LivePacer {
  static const _memory = 60;
  final List<int> _transits = [];
  double _jitter = 0;

  /// [sentAt] by the owner's clock, [now] by mine. Returns milliseconds.
  int holdFor(int sentAt, int now) {
    final transit = now - sentAt;
    _transits.add(transit);
    if (_transits.length > _memory) _transits.removeAt(0);
    final fastest = _transits.reduce((a, b) => a < b ? a : b);
    final lateness = transit - fastest;
    _jitter += (lateness - _jitter) / 8;
    final target = (_jitter * 2).round().clamp(0, kLiveMaxBufferMs);
    final hold = target - lateness;
    return hold > 0 ? hold : 0;
  }
}
