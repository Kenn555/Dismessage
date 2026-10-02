import 'dart:async';
import 'dart:math';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'id_store.dart';

/// Maximum accepted size of a raw WebSocket message (fits one image).
const int kMaxRawFrameLength = kMaxFrameLength;

class _Client {
  _Client(this.channel);
  final WebSocketChannel channel;
  String? id;

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
  Relay(this._ids, {Random? random, void Function(String line)? log})
    : _random = random ?? Random.secure(),
      _log = log ?? _silent;

  static void _silent(String _) {}

  final IdStore _ids;
  final void Function(String line) _log;
  final Random _random;
  final Map<String, _Client> _online = {};
  final Map<String, _Session> _sessions = {};

  /// Pending requests, as "from>to".
  final Set<String> _pending = {};

  int get onlineCount => _online.length;
  int get sessionCount => _sessions.length;

  /// Serves one WebSocket connection until it closes.
  ///
  /// [origin] (e.g. the forwarded client IP) only appears in the log.
  void handle(WebSocketChannel channel, {String? origin}) {
    final client = _Client(channel);
    final from = origin ?? '?';
    _log('+ connexion ($from)');
    // Frames of one client are processed in order, even across awaits.
    var queue = Future<void>.value();
    channel.stream.listen(
      (raw) => queue = queue.then((_) => _onRaw(client, raw)),
      onDone: () => queue = queue.then((_) {
        _log(
          '- déconnexion ${client.id == null ? '($from)' : _fmt(client.id!)}',
        );
        _unregister(client);
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
      case RegisterFrame(:final id, :final secret):
        await _register(client, id, secret);
      case ReleaseFrame(:final id, :final secret):
        if (await _ids.release(id, secret) && client.id == id) {
          _unregister(client);
        }
      case ConnectRequestFrame(:final to):
        _connectRequest(client, to);
      case ConnectAcceptFrame(:final from):
        _connectAccept(client, from);
      case ConnectRejectFrame(:final peer):
        _connectReject(client, peer);
      case ConnectCancelFrame(:final peer):
        _connectCancel(client, peer);
      case SessionLeaveFrame(:final sid):
        _leave(client, sid);
      case RelayedFrame():
        _relay(client, frame);
      default:
        _error(client, 'unexpected_frame', 'Trame "${frame.type}" refusée');
    }
  }

  Future<void> _register(_Client client, String id, String secret) async {
    if (!await _ids.claim(id, secret)) {
      _log("! ID ${_fmt(id)} refusé (appartient à quelqu'un d'autre)");
      client.send(IdTakenFrame(id: id));
      return;
    }
    if (client.id != null && client.id != id) _unregister(client);
    final previous = _online[id];
    if (previous != null && previous != client) {
      // Same ID connected elsewhere: the newest connection wins.
      _unregister(previous);
      previous.channel.sink.close();
    }
    client.id = id;
    _online[id] = client;
    client.send(RegisteredFrame(id: id));
    _log('  ID ${_fmt(id)} en ligne (${_online.length} en ligne)');
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

  void _unregister(_Client client) {
    final id = client.id;
    if (id == null) return;
    client.id = null;
    if (_online[id] == client) _online.remove(id);
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

  void _error(_Client client, String code, String message) =>
      client.send(ErrorFrame(code: code, message: message));

  String _newSid() => List.generate(
    16,
    (_) => _random.nextInt(16),
  ).map((n) => n.toRadixString(16)).join();

  static String _fmt(String id) =>
      DismessageId.isValid(id) ? DismessageId.format(id) : id;
}
