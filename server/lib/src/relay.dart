import 'dart:async';
import 'dart:math';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'id_signer.dart';
import 'id_store.dart';
import 'rate_limit.dart';

/// Maximum accepted size of a raw WebSocket message (fits one image).
const int kMaxRawFrameLength = kMaxFrameLength;

class _Client {
  _Client(this.channel, this.ip, this.limiter);
  final WebSocketChannel channel;
  final IpLimiter ip;
  final ConnectionLimiter limiter;
  String? id;

  /// Limits already logged for this connection (one line each, not a flood).
  final Set<String> loggedLimits = {};

  /// IDs whose presence this client follows.
  Set<String> watching = {};

  void send(Frame frame) => channel.sink.add(frame.encode());
}

class _Session {
  _Session(this.sid, this.a, this.b);
  final String sid;
  final String a;
  final String b;

  bool involves(String id) => id == a || id == b;
  String other(String id) => id == a ? b : a;
}

/// Routes frames between clients: registration, pairing and session relay.
class Relay {
  Relay(
    this._ids, {
    Random? random,
    void Function(String line)? log,
    RateLimits limits = const RateLimits(),
    DateTime Function()? clock,
    IdSigner? signer,
    this.acceptLegacyIds = false,
    this.minProtocolVersion = kMinProtocolVersion,
  }) : _random = random ?? Random.secure(),
       _log = log ?? _silent,
       _limits = limits,
       _clock = clock ?? DateTime.now,
       signer = signer ?? IdSigner.random() {
    _ips = IpLimiters(_limits, _clock);
  }

  static void _silent(String _) {}

  final IdStore _ids;

  /// Signs the IDs this relay hands out (`id_request`).
  final IdSigner signer;

  /// Transition from older clients, which chose their own ID and secret:
  /// an unknown ID is then claimed by whoever comes first (anyone can take
  /// an offline ID after a restart). Off: only signed or known IDs.
  final bool acceptLegacyIds;

  /// Older clients are refused with `update_required`, which they show.
  final int minProtocolVersion;
  final RateLimits _limits;
  final DateTime Function() _clock;
  late final IpLimiters _ips;
  final void Function(String line) _log;
  final Random _random;
  final Map<String, _Client> _online = {};
  final Map<String, _Session> _sessions = {};

  /// Watched ID → clients following its presence.
  final Map<String, Set<_Client>> _watchers = {};

  /// Pending requests, as "from>to".
  final Set<String> _pending = {};

  int get onlineCount => _online.length;
  int get sessionCount => _sessions.length;

  /// Serves one WebSocket connection until it closes.
  ///
  /// [origin] (e.g. the forwarded client IP) only appears in the log.
  /// [origin] (the client IP) also groups connections for the per-IP limits.
  void handle(WebSocketChannel channel, {String? origin}) {
    final from = origin ?? '?';
    final ip = _ips[from];
    if (ip.connections >= _limits.connectionsPerIp) {
      _log('! connexion refusée ($from) : trop de connexions');
      channel.sink.add(
        const ErrorFrame(
          code: ErrorCodes.tooManyConnections,
          message: 'Trop de connexions depuis cette adresse.',
        ).encode(),
      );
      channel.sink.close();
      return;
    }
    ip.connections++;
    final client = _Client(channel, ip, ConnectionLimiter(_limits, _clock));
    _log('+ connexion ($from)');
    // Frames of one client are processed in order, even across awaits.
    var queue = Future<void>.value();
    late final StreamSubscription<Object?> subscription;
    subscription = channel.stream.listen(
      (raw) {
        // Over its throughput, a client is not read for a while: the socket
        // pushes back and the sender slows down, without losing a frame.
        final length = switch (raw) {
          String() => raw.length,
          List<int>() => raw.length,
          _ => 0,
        };
        final wait = client.limiter.throttle(length);
        if (wait > Duration.zero) subscription.pause(Future.delayed(wait));
        queue = queue.then((_) => _onRaw(client, raw));
      },
      onDone: () => queue = queue.then((_) {
        _log(
          '- déconnexion ${client.id == null ? '($from)' : _fmt(client.id!)}',
        );
        ip.connections--;
        _unregister(client);
        _watch(client, const []);
      }),
      onError: (_) {},
      cancelOnError: false,
    );
  }

  Future<void> _onRaw(_Client client, Object? raw) async {
    if (raw is String && raw.length > kMaxRawFrameLength) {
      return _error(client, 'too_large', 'Trame trop volumineuse');
    }
    final Frame frame;
    try {
      frame = Frame.decode(raw);
    } on FrameFormatException catch (e) {
      return _error(client, 'bad_frame', e.message);
    }
    try {
      await _onFrame(client, frame);
    } catch (e) {
      _error(client, 'internal', 'Erreur interne');
    }
  }

  Future<void> _onFrame(_Client client, Frame frame) async {
    switch (frame) {
      case PingFrame():
        client.send(const PongFrame());
      case RegisterFrame(:final v) when v < minProtocolVersion:
        _error(
          client,
          ErrorCodes.updateRequired,
          "Cette version de Dismessage n'est plus acceptée : "
          'installez la nouvelle.',
        );
      case RegisterFrame(:final id, :final secret):
        await _register(client, id, secret);
      case IdRequestFrame():
        await _assignId(client);
      case ReleaseFrame(:final id, :final secret):
        await _release(client, id, secret);
      case ConnectRequestFrame(:final to):
        _connectRequest(client, to);
      case ConnectAcceptFrame(:final from):
        _connectAccept(client, from);
      case ConnectRejectFrame(:final peer):
        _connectReject(client, peer);
      case ConnectCancelFrame(:final peer):
        _connectCancel(client, peer);
      case PresenceWatchFrame(:final ids):
        if (_requireId(client) == null) return;
        if (!client.limiter.watches.tryTake()) {
          return _rateLimited(client, 'présence');
        }
        _watch(client, ids);
      case SessionLeaveFrame(:final sid):
        _leave(client, sid);
      case KeyOfferFrame() || SealedFrame():
        _relay(client, frame as RelayedFrame);
      case RelayedFrame():
        // Conversations are end-to-end encrypted: nothing else passes.
        _error(client, 'unencrypted', 'Trame non chiffrée refusée');
      default:
        _error(client, 'unexpected_frame', 'Trame "${frame.type}" refusée');
    }
  }

  /// Ownership, in order: a secret signed by this relay (survives a lost
  /// store); the secret recorded for a known ID (older clients, upgraded to
  /// a signed secret on the way); an unknown ID claimed first-come, only
  /// with [acceptLegacyIds].
  Future<void> _register(_Client client, String id, String secret) async {
    if (!client.ip.registers.tryTake()) {
      return _rateLimited(client, 'enregistrements');
    }
    var upgrade = false;
    if (signer.verify(id, secret)) {
      // Known again after a restart: kept out of the IDs handed out.
      await _ids.put(id, secret);
    } else if (_ids.contains(id)) {
      if (!await _ids.claim(id, secret)) {
        _log("! ID ${_fmt(id)} refusé (appartient à quelqu'un d'autre)");
        client.send(IdTakenFrame(id: id));
        return;
      }
      upgrade = true;
    } else if (acceptLegacyIds) {
      // Every new ID grows the store: one IP cannot claim thousands of them.
      if (!client.ip.newIds.tryTake()) {
        return _rateLimited(client, 'nouveaux IDs');
      }
      await _ids.claim(id, secret);
      upgrade = true;
    } else {
      return _error(
        client,
        ErrorCodes.unsignedId,
        'Cette version de Dismessage est trop ancienne : '
        'installez la nouvelle pour obtenir un ID.',
      );
    }
    if (upgrade) {
      // The same ID, with a secret that outlives the store. The store keeps
      // the old one: an older client ignores this frame and comes back with
      // it.
      client.send(IdAssignedFrame(id: id, secret: signer.sign(id)));
    }
    if (client.id != null && client.id != id) _unregister(client);
    final previous = _online[id];
    if (previous != null && previous != client) {
      // Same ID connected elsewhere: the newest connection wins. It stays
      // online for its watchers.
      _unregister(previous, silent: true);
      previous.channel.sink.close();
    }
    client.id = id;
    _online[id] = client;
    client.send(RegisteredFrame(id: id));
    if (previous == null) _notifyPresence(id, online: true);
    _log('  ID ${_fmt(id)} en ligne (${_online.length} en ligne)');
  }

  /// Frees [id] (a new one replaced it). A signed secret stays valid, but
  /// only its owner held it, and the new ID's register has replaced it.
  Future<void> _release(_Client client, String id, String secret) async {
    final bool owned;
    if (signer.verify(id, secret)) {
      await _ids.remove(id);
      owned = true;
    } else {
      owned = await _ids.release(id, secret);
    }
    if (owned && client.id == id) _unregister(client);
  }

  /// Picks a free ID and sends it with its signed secret. Free = neither
  /// online nor in the store; an offline owner unknown since a restart
  /// could still be picked (1 chance in 900 million per owner).
  Future<void> _assignId(_Client client) async {
    // Each one grows the store: one IP cannot get thousands of them.
    if (!client.ip.newIds.tryTake()) {
      return _rateLimited(client, 'nouveaux IDs');
    }
    for (var attempt = 0; attempt < 100; attempt++) {
      final id = DismessageId.generate(_random);
      if (_online.containsKey(id) || _ids.contains(id)) continue;
      final secret = signer.sign(id);
      await _ids.put(id, secret);
      client.send(IdAssignedFrame(id: id, secret: secret));
      _log('  nouvel ID ${_fmt(id)} attribué');
      return;
    }
    _error(client, 'internal', 'Aucun ID libre trouvé');
  }

  void _connectRequest(_Client client, String to) {
    final me = _requireId(client);
    if (me == null) return;
    if (to == me) {
      return _error(
        client,
        'self_connect',
        'Impossible de se connecter à soi-même',
      );
    }
    // Counted even for an offline target: probing IDs costs the same.
    if (!client.limiter.requests.tryTake() || !client.ip.requests.tryTake()) {
      return _rateLimited(client, 'demandes');
    }
    final target = _online[to];
    if (target == null) {
      client.send(PeerOfflineFrame(peer: to));
      return;
    }
    _pending.add('$me>$to');
    target.send(IncomingRequestFrame(from: me));
    _log('  demande ${_fmt(me)} → ${_fmt(to)}');
  }

  void _connectAccept(_Client client, String from) {
    final me = _requireId(client);
    if (me == null) return;
    final requester = _online[from];
    if (!_pending.remove('$from>$me') || requester == null) {
      return _error(client, 'no_request', 'Aucune demande de $from');
    }
    final sid = _newSid();
    _sessions[sid] = _Session(sid, from, me);
    _log('  conversation ${_fmt(from)} ↔ ${_fmt(me)}');
    requester.send(SessionStartedFrame(sid: sid, peer: me));
    client.send(SessionStartedFrame(sid: sid, peer: from));
  }

  void _connectCancel(_Client client, String peer) {
    final me = _requireId(client);
    if (me == null) return;
    if (_pending.remove('$me>$peer')) {
      _online[peer]?.send(ConnectCancelFrame(peer: me));
    }
  }

  void _connectReject(_Client client, String peer) {
    final me = _requireId(client);
    if (me == null) return;
    if (_pending.remove('$peer>$me')) {
      _online[peer]?.send(ConnectRejectFrame(peer: me));
    }
  }

  void _relay(_Client client, RelayedFrame frame) {
    final me = client.id;
    final session = _sessions[frame.sid];
    if (me == null || session == null || !session.involves(me)) {
      return _error(client, 'unknown_session', 'Session inconnue');
    }
    _online[session.other(me)]?.send(frame);
  }

  void _leave(_Client client, String sid) {
    final me = client.id;
    final session = _sessions[sid];
    if (me == null || session == null || !session.involves(me)) return;
    _sessions.remove(sid);
    _online[session.other(me)]?.send(PeerLeftFrame(sid: sid));
  }

  /// Replaces the IDs [client] follows and tells it their current state.
  void _watch(_Client client, List<String> ids) {
    for (final id in client.watching) {
      final watchers = _watchers[id];
      watchers?.remove(client);
      if (watchers != null && watchers.isEmpty) _watchers.remove(id);
    }
    client.watching = ids.toSet();
    for (final id in client.watching) {
      (_watchers[id] ??= {}).add(client);
      client.send(PresenceFrame(id: id, online: _online.containsKey(id)));
    }
  }

  void _notifyPresence(String id, {required bool online}) {
    for (final watcher in _watchers[id]?.toList() ?? const <_Client>[]) {
      watcher.send(PresenceFrame(id: id, online: online));
    }
  }

  /// [silent]: the ID reconnects elsewhere, so watchers are not told.
  void _unregister(_Client client, {bool silent = false}) {
    final id = client.id;
    if (id == null) return;
    client.id = null;
    if (_online[id] == client) {
      _online.remove(id);
      if (!silent) _notifyPresence(id, online: false);
    }
    // Close pending requests on both sides so no dialog stays open.
    for (final pending in _pending.toList()) {
      final [from, to] = pending.split('>');
      if (from == id) {
        _online[to]?.send(ConnectCancelFrame(peer: id));
      } else if (to == id) {
        _online[from]?.send(PeerOfflineFrame(peer: id));
      } else {
        continue;
      }
      _pending.remove(pending);
    }
    final ended = _sessions.values.where((s) => s.involves(id)).toList();
    for (final session in ended) {
      _sessions.remove(session.sid);
      _online[session.other(id)]?.send(PeerLeftFrame(sid: session.sid));
    }
  }

  String? _requireId(_Client client) {
    final id = client.id;
    if (id == null) _error(client, 'not_registered', 'Enregistrement requis');
    return id;
  }

  void _rateLimited(_Client client, String what) {
    if (client.loggedLimits.add(what)) {
      final who = client.id == null ? '' : ' ${_fmt(client.id!)}';
      _log('! limite atteinte ($what)$who');
    }
    _error(
      client,
      ErrorCodes.rateLimited,
      'Trop de tentatives, réessayez dans un instant.',
    );
  }

  void _error(_Client client, String code, String message) =>
      client.send(ErrorFrame(code: code, message: message));

  String _newSid() => List.generate(
    16,
    (_) => _random.nextInt(16),
  ).map((n) => n.toRadixString(16)).join();

  static String _fmt(String id) =>
      DismessageId.isValid(id) ? DismessageId.format(id) : id;
}
