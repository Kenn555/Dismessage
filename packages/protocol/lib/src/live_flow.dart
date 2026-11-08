import 'constants.dart';

/// Camera owner side of a live view: whether the next frame may leave, at which
/// size, and at which JPEG quality or video bitrate.
///
/// Latency comes first. At most [window] frames travel at once: on a slow
/// network frames are skipped (before being encoded) instead of piling up in
/// the sockets and the relay. As in video calls, the view adapts to keep its
/// rate, from the delay above the lowest measured (frames queueing somewhere).
/// A queue that lasts ([kLiveSlowAcksToLower] late acknowledgements in a row,
/// or one very late) makes it lighter: the bitrate (or the JPEG quality) goes
/// down, then the size. After [kLiveCalmMs] without any late one, it gets
/// richer: the size first while the image is good enough, up to [maxSide].
/// One late frame alone, common through a relay that delivers in bursts,
/// changes nothing: it used to bring full screen down to the smallest size
/// for good.
///
/// There is no timer between frames: the camera gives the pace, each frame
/// being the next image it delivers. A timer would make things worse: one of
/// 25 ms lasts 31 ms on Windows, which then misses every other image of a
/// 30 images per second camera.
///
/// Times are milliseconds from any fixed origin, given by the caller.
class LiveFlow {
  /// [video]: frames of a video codec, whose weight is set by [kbps]; else
  /// JPEG, by [quality].
  LiveFlow({this.video = false})
    : _maxSide = video ? kLiveVideoSmallSide : kLiveMaxSide,
      _side = video ? kLiveVideoSmallSide : kLiveMaxSide,
      _kbps = kLiveStartKbps;

  final bool video;
  final Map<int, int> _inFlight = {};
  int _next = 1;
  int? _lastAdjustAt;

  /// The last late acknowledgement, or the first frame: calm is measured
  /// from there.
  int? _lastSlowAt;
  int _slowInARow = 0;
  int? _lastRtt;
  final List<(int at, int rtt)> _rtts = [];
  int _quality = kLiveQualityStart;
  int _kbps;
  int _maxSide;
  int _side;

  /// JPEG quality of the next frame.
  int get quality => _quality;

  /// Video bitrate, in kbit/s.
  int get kbps => _kbps;

  /// Longest side of the next frame.
  int get side => _side;

  /// Frames sent and not acknowledged yet.
  int get inFlight => _inFlight.length;

  /// The small view's size.
  int get smallSide => video ? kLiveVideoSmallSide : kLiveMaxSide;

  /// Longest side the viewer can use: more in full screen.
  int get maxSide => _maxSide;
  set maxSide(int value) {
    // The viewer asks for the small view's size of JPEG ([kLiveMaxSide]):
    // video affords more.
    final wanted = value < smallSide ? smallSide : value;
    if (wanted == _maxSide) return;
    _maxSide = wanted;
    if (wanted > smallSide) {
      final start = video ? kLiveVideoFullStartSide : kLiveFullStartSide;
      _side = wanted < start ? wanted : start;
      if (video && _kbps < kLiveFullStartKbps) _kbps = kLiveFullStartKbps;
    } else {
      _side = wanted;
      if (video) _kbps = _kbps.clamp(kLiveMinKbps, maxKbpsFor(_side));
    }
  }

  /// Highest bitrate worth spending on frames of [side] pixels.
  static int maxKbpsFor(int side) {
    for (var i = 0; i < kLiveSideSteps.length; i++) {
      if (side <= kLiveSideSteps[i]) return kLiveMaxKbpsBySide[i];
    }
    return kLiveMaxKbpsBySide.last;
  }

  /// Below this bitrate, [side] pixels would look worse than fewer, sharper.
  static int minKbpsFor(int side) => maxKbpsFor(side) ~/ 3;

  /// Lowest delay measured between a frame and its acknowledgement, in
  /// milliseconds, over the last [kLiveRttMemoryMs]: the distance, without any
  /// queue.
  int? get lowestRtt {
    if (_rtts.isEmpty) return null;
    var lowest = _rtts.first.$2;
    for (final (_, rtt) in _rtts) {
      if (rtt < lowest) lowest = rtt;
    }
    return lowest;
  }

  /// Last delay measured.
  int? get lastRtt => _lastRtt;

  /// Frames that may travel at once: what [kLiveTargetFps] puts on the way
  /// during [lowestRtt], with a margin for a relay that delivers in bursts. A
  /// fixed number would send bursts separated by gaps on a distant relay; this
  /// keeps a steady flow, and frames queueing are skipped all the same.
  int get window {
    final lowest = lowestRtt ?? 0;
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
    _kbps = kLiveMinKbps;
    _side = smallSide;
    _lastAdjustAt = now;
    _lastSlowAt = now;
    _slowInARow = 0;
    return true;
  }

  /// A frame leaves now; returns its number.
  int sent(int now) {
    final n = _next++;
    _inFlight[n] = now;
    _lastSlowAt ??= now;
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
    if (video) {
      _lighter();
    } else if (!_stepSideDown()) {
      _quality = _clampQuality(_quality - 10);
    }
  }

  void _adapt(int rtt, int now) {
    _lastRtt = rtt;
    _rtts.add((now, rtt));
    while (_rtts.length > 1 && now - _rtts.first.$1 > kLiveRttMemoryMs) {
      _rtts.removeAt(0);
    }
    final base = lowestRtt!;
    // Only what comes on top of the distance: a far relay is not a slow one.
    final queue = rtt - base;
    if (queue > kLiveQueueDelayMs) {
      _slowInARow++;
      _lastSlowAt = now;
    } else {
      _slowInARow = 0;
    }
    // At most twice per second: the effect of a change takes a moment.
    final last = _lastAdjustAt;
    if (last != null && now - last < 500) return;
    if (_slowInARow >= kLiveSlowAcksToLower || queue > kLiveCongestedDelayMs) {
      _lighter();
      _slowInARow = 0;
    } else if (queue < kLiveClearDelayMs &&
        now - (_lastSlowAt ?? now) >= kLiveCalmMs) {
      _richer();
    } else {
      return;
    }
    _lastAdjustAt = now;
  }

  void _lighter() {
    if (video) {
      _kbps = (_kbps * 0.7).round();
      if (_kbps < minKbpsFor(_side) && _stepSideDown()) {
        _kbps = _kbps.clamp(minKbpsFor(_side), maxKbpsFor(_side));
      }
      if (_kbps < kLiveMinKbps) _kbps = kLiveMinKbps;
    } else if (!_stepSideDown()) {
      _quality = _clampQuality(_quality - 8);
    }
  }

  void _richer() {
    if (video) {
      final ceiling = maxKbpsFor(_side);
      if (_kbps < ceiling) {
        _kbps = (_kbps * 1.15).round().clamp(kLiveMinKbps, ceiling);
      } else {
        _stepSideUp();
      }
    } else if (_quality < kLiveQualityStart) {
      _quality = _clampQuality(_quality + 5);
    } else if (!_stepSideUp()) {
      _quality = _clampQuality(_quality + 5);
    }
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

  bool _stepSideUp() {
    final higher = kLiveSideSteps.firstWhere(
      (step) => step > _side,
      orElse: () => _side,
    );
    if (higher == _side || higher > _maxSide) return false;
    _side = higher;
    return true;
  }

  static int _clampQuality(int quality) =>
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
