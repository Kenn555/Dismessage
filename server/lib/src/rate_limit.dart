import 'package:dismessage_protocol/dismessage_protocol.dart';

/// Token bucket: holds up to [capacity] tokens, refilled at [perSecond].
class TokenBucket {
  TokenBucket(this.capacity, this.perSecond, this._clock)
    : _tokens = capacity.toDouble(),
      _at = _clock();

  final int capacity;
  final double perSecond;
  final DateTime Function() _clock;
  double _tokens;
  DateTime _at;

  void _refill() {
    final now = _clock();
    final elapsed = now.difference(_at).inMicroseconds / 1e6;
    _at = now;
    if (elapsed > 0) {
      _tokens = (_tokens + elapsed * perSecond).clamp(
        double.negativeInfinity,
        capacity.toDouble(),
      );
    }
  }

  /// Takes [cost] tokens if available: false (nothing taken) otherwise.
  bool tryTake([num cost = 1]) {
    _refill();
    if (_tokens < cost) return false;
    _tokens -= cost;
    return true;
  }

  /// Always takes [cost], going into debt: returns how long to wait until
  /// the bucket is out of debt (zero if it is not).
  Duration reserve(num cost) {
    _refill();
    _tokens -= cost;
    if (_tokens >= 0) return Duration.zero;
    return Duration(microseconds: (-_tokens / perSecond * 1e6).ceil());
  }

  /// Back to full: forgetting it changes nothing.
  bool get isFull {
    _refill();
    return _tokens >= capacity;
  }
}

/// Limits applied by the relay, per connection and per client IP.
///
/// Throughput (frames, bytes) is throttled: reading pauses, which slows a
/// file transfer down but never breaks it. Actions that reach other people
/// or the ID store are refused with a `rate_limited` error instead.
class RateLimits {
  const RateLimits({
    this.framesBurst = kRateFramesBurst,
    this.framesPerSecond = kRateFramesPerSecond,
    this.bytesBurst = kRateBytesBurst,
    this.bytesPerSecond = kRateBytesPerSecond,
    this.requestsBurst = kRateRequestsBurst,
    this.requestsPerMinute = kRateRequestsPerMinute,
    this.ipRequestsBurst = kRateIpRequestsBurst,
    this.ipRequestsPerMinute = kRateIpRequestsPerMinute,
    this.ipRegistersBurst = kRateIpRegistersBurst,
    this.ipRegistersPerMinute = kRateIpRegistersPerMinute,
    this.ipNewIdsBurst = kRateIpNewIdsBurst,
    this.ipNewIdsPerHour = kRateIpNewIdsPerHour,
    this.watchesBurst = kRateWatchesBurst,
    this.watchesPerMinute = kRateWatchesPerMinute,
    this.connectionsPerIp = kMaxConnectionsPerIp,
  });

  /// No limit at all (tests that are not about limits).
  static const RateLimits none = RateLimits(
    framesBurst: 1 << 30,
    framesPerSecond: 1 << 30,
    bytesBurst: 1 << 40,
    bytesPerSecond: 1 << 40,
    requestsBurst: 1 << 30,
    requestsPerMinute: 1 << 30,
    ipRequestsBurst: 1 << 30,
    ipRequestsPerMinute: 1 << 30,
    ipRegistersBurst: 1 << 30,
    ipRegistersPerMinute: 1 << 30,
    ipNewIdsBurst: 1 << 30,
    ipNewIdsPerHour: 1 << 30,
    watchesBurst: 1 << 30,
    watchesPerMinute: 1 << 30,
    connectionsPerIp: 1 << 30,
  );

  final int framesBurst;
  final int framesPerSecond;
  final int bytesBurst;
  final int bytesPerSecond;

  /// Chat requests (`connect_request`) of one connection.
  final int requestsBurst;
  final int requestsPerMinute;

  /// Chat requests of all connections of one IP.
  final int ipRequestsBurst;
  final int ipRequestsPerMinute;

  /// `register` attempts of one IP (reconnections included).
  final int ipRegistersBurst;
  final int ipRegistersPerMinute;

  /// IDs never seen before, claimed from one IP (each one grows the store).
  final int ipNewIdsBurst;
  final int ipNewIdsPerHour;

  /// `presence_watch` of one connection (each one answers up to
  /// [kMaxPresenceWatch] frames).
  final int watchesBurst;
  final int watchesPerMinute;

  /// Simultaneous connections of one IP.
  final int connectionsPerIp;
}

/// Buckets of one connection.
class ConnectionLimiter {
  ConnectionLimiter(RateLimits limits, DateTime Function() clock)
    : frames = TokenBucket(
        limits.framesBurst,
        limits.framesPerSecond.toDouble(),
        clock,
      ),
      bytes = TokenBucket(
        limits.bytesBurst,
        limits.bytesPerSecond.toDouble(),
        clock,
      ),
      requests = TokenBucket(
        limits.requestsBurst,
        limits.requestsPerMinute / 60,
        clock,
      ),
      watches = TokenBucket(
        limits.watchesBurst,
        limits.watchesPerMinute / 60,
        clock,
      );

  final TokenBucket frames;
  final TokenBucket bytes;
  final TokenBucket requests;
  final TokenBucket watches;

  /// How long to stop reading after a raw message of [length] characters.
  Duration throttle(int length) {
    final a = frames.reserve(1);
    final b = bytes.reserve(length);
    return a > b ? a : b;
  }
}

/// Buckets and open connections of one client IP.
class IpLimiter {
  IpLimiter(RateLimits limits, DateTime Function() clock)
    : requests = TokenBucket(
        limits.ipRequestsBurst,
        limits.ipRequestsPerMinute / 60,
        clock,
      ),
      registers = TokenBucket(
        limits.ipRegistersBurst,
        limits.ipRegistersPerMinute / 60,
        clock,
      ),
      newIds = TokenBucket(
        limits.ipNewIdsBurst,
        limits.ipNewIdsPerHour / 3600,
        clock,
      );

  final TokenBucket requests;
  final TokenBucket registers;
  final TokenBucket newIds;
  int connections = 0;

  /// Nothing to remember: can be dropped and recreated later.
  bool get idle =>
      connections == 0 && requests.isFull && registers.isFull && newIds.isFull;
}

/// Per-IP limiters, pruned when they grow (an IP not seen for a while is
/// back to full buckets).
class IpLimiters {
  IpLimiters(this._limits, this._clock);

  final RateLimits _limits;
  final DateTime Function() _clock;
  final Map<String, IpLimiter> _byIp = {};

  /// Above this many IPs, idle ones are forgotten.
  static const int _pruneAbove = 10000;

  int get length => _byIp.length;

  IpLimiter operator [](String ip) {
    final existing = _byIp[ip];
    if (existing != null) return existing;
    if (_byIp.length >= _pruneAbove) {
      _byIp.removeWhere((_, limiter) => limiter.idle);
    }
    return _byIp[ip] = IpLimiter(_limits, _clock);
  }
}
