import 'dart:async';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'chat_session.dart';
import 'identity_service.dart';

enum ServerStatus { offline, connecting, online }

/// One-shot notifications for the UI (dialogs, snackbars, navigation).
sealed class ConnectionEvent {
  const ConnectionEvent();
}

class IncomingRequestEvent extends ConnectionEvent {
  const IncomingRequestEvent(this.from);
  final String from;
}

class SessionStartedEvent extends ConnectionEvent {
  const SessionStartedEvent(this.session);
  final ChatSession session;
}

class PeerOfflineEvent extends ConnectionEvent {
  const PeerOfflineEvent(this.peer);
  final String peer;
}

class RequestRejectedEvent extends ConnectionEvent {
  const RequestRejectedEvent(this.peer);
  final String peer;
}

/// The peer did not answer within [kConnectRequestTimeoutSeconds].
class RequestTimedOutEvent extends ConnectionEvent {
  const RequestTimedOutEvent(this.peer);
  final String peer;
}

/// The request of [from] was answered (from its dialog or a notification):
/// close what still shows it.
class IncomingRequestAnsweredEvent extends ConnectionEvent {
  const IncomingRequestAnsweredEvent(this.from);
  final String from;
}

/// [from] withdrew the request they sent us (close the dialog).
class RequestCancelledEvent extends ConnectionEvent {
  const RequestCancelledEvent(this.from);
  final String from;
}

class ServerErrorEvent extends ConnectionEvent {
  const ServerErrorEvent(this.code, this.message);
  final String code;
  final String message;
}

typedef ChannelFactory = WebSocketChannel Function(Uri uri);

/// Keeps the connection to the relay alive and dispatches its frames.
class ConnectionService extends ChangeNotifier {
  ConnectionService({
    required IdentityService identity,
    required Uri serverUri,
    ChannelFactory? connect,
    this.reconnectDelay = const Duration(seconds: 2),
    this.connectTimeout = const Duration(seconds: kConnectTimeoutSeconds),
  }) : _identity = identity,
       _serverUri = serverUri,
       _connect = connect ?? WebSocketChannel.connect;

  final IdentityService _identity;
  final ChannelFactory _connect;
  final Duration reconnectDelay;
  final Duration connectTimeout;
  final _events = StreamController<ConnectionEvent>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _subscription;
  Timer? _heartbeat;
  Timer? _reconnectTimer;
  Timer? _requestTimer;
  Timer? _registerTimer;
  int _failures = 0;
  String? _lastError;
  DateTime? _nextRetryAt;
  String? _pendingRequest;
  Identity? _me;
  Identity? _pendingRelease;
  ChatSession? _session;
  ServerStatus _status = ServerStatus.offline;
  bool _disposed = false;
  bool _suspended = false;
  Uri _serverUri;
  Set<String> _watched = {};
  final Map<String, bool> _presence = {};

  /// Incremented on every server change, to drop stale connection attempts.
  int _generation = 0;

  Stream<ConnectionEvent> get events => _events.stream;
  ServerStatus get status => _status;
  String? get myId => _me?.id;
  ChatSession? get session => _session;
  Uri get serverUri => _serverUri;

  /// Consecutive failed connection attempts (0 once online).
  int get failures => _failures;

  /// Why the last attempt failed, in French, for the user.
  String? get lastError => _lastError;

  /// When the next automatic attempt happens, if one is scheduled.
  DateTime? get nextRetryAt => _nextRetryAt;

  /// Skips the reconnection delay.
  Future<void> retryNow() async {
    if (_status == ServerStatus.online || _channel != null) return;
    _reconnectTimer?.cancel();
    await _open();
  }

  /// ID we are waiting an answer from, if any.
  String? get pendingRequest => _pendingRequest;

  /// Whether [id] is connected to the relay; null while unknown (not
  /// watched, or we are offline ourselves).
  bool? isOnline(String id) => _presence[id];

  /// Follows the presence of [ids] (the contacts), replacing the previous
  /// list. Sent again after every reconnection.
  void watchPresence(Iterable<String> ids) {
    final next = ids.take(kMaxPresenceWatch).toSet();
    if (setEquals(next, _watched)) return;
    _watched = next;
    _presence.removeWhere((id, _) => !next.contains(id));
    if (_status == ServerStatus.online) _sendWatch();
    notifyListeners();
  }

  void _sendWatch() => _send(PresenceWatchFrame(ids: _watched.toList()));

  Future<void> start() async {
    _me ??= await _identity.load();
    notifyListeners();
    await _open();
  }

  void requestChat(String peerId) {
    cancelRequest();
    _pendingRequest = peerId;
    _requestTimer = Timer(
      const Duration(seconds: kConnectRequestTimeoutSeconds),
      () {
        cancelRequest();
        _events.add(RequestTimedOutEvent(peerId));
      },
    );
    _send(ConnectRequestFrame(to: peerId));
    notifyListeners();
  }

  /// Withdraws the pending request; the peer's dialog closes.
  void cancelRequest() {
    final peer = _pendingRequest;
    if (peer == null) return;
    _send(ConnectCancelFrame(peer: peer));
    _clearRequest();
  }

  /// Forgets the pending request, if it targets [peer] (or any when null).
  void _clearRequest([String? peer]) {
    if (_pendingRequest == null) return;
    if (peer != null && peer != _pendingRequest) return;
    _requestTimer?.cancel();
    _requestTimer = null;
    _pendingRequest = null;
    if (!_disposed) notifyListeners();
  }

  void accept(String from) {
    _send(ConnectAcceptFrame(from: from));
    _events.add(IncomingRequestAnsweredEvent(from));
  }

  void reject(String from) {
    _send(ConnectRejectFrame(peer: from));
    _events.add(IncomingRequestAnsweredEvent(from));
  }

  /// Leaves the current conversation (the peer is notified).
  void leaveSession() {
    final session = _session;
    if (session == null) return;
    _session = null;
    if (!session.peerLeft) _send(SessionLeaveFrame(sid: session.sid));
    session.dispose();
    notifyListeners();
  }

  /// Switches to a brand new ID; the old one is released on the server.
  Future<void> regenerateId() async {
    leaveSession();
    _pendingRelease ??= _me;
    _me = await _identity.regenerate();
    if (_status != ServerStatus.offline) {
      _setStatus(ServerStatus.connecting);
      _register();
    }
    notifyListeners();
  }

  /// The page is being left (web): the browser may keep it frozen in its
  /// back/forward cache with the socket open, so we would still look
  /// online. Close the connection; [resume] reopens it.
  void suspend() {
    if (_disposed || _suspended) return;
    _suspended = true;
    _generation++;
    _reconnectTimer?.cancel();
    _clearRequest();
    final channel = _channel;
    _closeChannel();
    channel?.sink.close();
    _session?.markPeerLeft();
    _setStatus(ServerStatus.offline);
  }

  /// The page is shown again after [suspend].
  Future<void> resume() async {
    if (!_suspended) return;
    _suspended = false;
    await _open();
  }

  /// Connects to another relay (e.g. a new VS Code tunnel link).
  Future<void> setServerUri(Uri uri) async {
    if (uri == _serverUri) return;
    _serverUri = uri;
    _generation++;
    _reconnectTimer?.cancel();
    _clearRequest();
    final channel = _channel;
    _closeChannel();
    _session?.markPeerLeft();
    await channel?.sink.close();
    notifyListeners();
    await _open();
  }

  Future<void> _open() async {
    if (_disposed || _suspended) return;
    final generation = _generation;
    _setStatus(ServerStatus.connecting);
    final WebSocketChannel channel;
    try {
      channel = _connect(_serverUri);
      await channel.ready.timeout(connectTimeout);
    } on TimeoutException {
      if (generation == _generation) {
        _fail(
          'Le serveur ne répond pas '
          '(délai de ${connectTimeout.inSeconds} s dépassé).',
        );
      }
      return;
    } catch (e) {
      if (generation == _generation) {
        _fail(
          'Connexion impossible au serveur ($_serverUri) : '
          '${_describe(e)}',
        );
      }
      return;
    }
    if (_disposed || generation != _generation) {
      await channel.sink.close();
      return;
    }
    _channel = channel;
    _subscription = channel.stream.listen(
      _onRaw,
      onDone: _onClosed,
      onError: (_) {},
    );
    _register();
    _heartbeat = Timer.periodic(
      const Duration(seconds: kHeartbeatSeconds),
      (_) => _send(const PingFrame()),
    );
  }

  void _register() {
    final me = _me!;
    _send(RegisterFrame(id: me.id, secret: me.secret));
    _registerTimer?.cancel();
    _registerTimer = Timer(connectTimeout, () {
      if (_status == ServerStatus.online) return;
      final channel = _channel;
      _closeChannel();
      channel?.sink.close();
      _fail("Le serveur n'a pas confirmé l'enregistrement de l'ID.");
    });
  }

  Future<void> _onRaw(Object? raw) async {
    final Frame frame;
    try {
      frame = Frame.decode(raw);
    } on FrameFormatException {
      return;
    }
    switch (frame) {
      case RegisteredFrame(:final id) when id == _me?.id:
        final old = _pendingRelease;
        _pendingRelease = null;
        if (old != null) _send(ReleaseFrame(id: old.id, secret: old.secret));
        _registerTimer?.cancel();
        _failures = 0;
        _lastError = null;
        _nextRetryAt = null;
        if (_watched.isNotEmpty) _sendWatch();
        _setStatus(ServerStatus.online);
      case PresenceFrame(:final id, :final online):
        if (!_watched.contains(id) || _presence[id] == online) return;
        _presence[id] = online;
        notifyListeners();
      case IdTakenFrame(:final id) when id == _me?.id:
        // Someone else owns this ID on the server: pick a new one.
        _me = await _identity.regenerate();
        _register();
        notifyListeners();
      case IncomingRequestFrame(:final from):
        _events.add(IncomingRequestEvent(from));
      case SessionStartedFrame(:final sid, :final peer):
        _clearRequest();
        leaveSession();
        final session = ChatSession(sid: sid, peer: peer, send: _send);
        _session = session;
        notifyListeners();
        _events.add(SessionStartedEvent(session));
      case PeerOfflineFrame(:final peer):
        _clearRequest(peer);
        _events.add(PeerOfflineEvent(peer));
      case ConnectRejectFrame(:final peer):
        _clearRequest(peer);
        _events.add(RequestRejectedEvent(peer));
      case ConnectCancelFrame(:final peer):
        _events.add(RequestCancelledEvent(peer));
      case PeerLeftFrame(:final sid):
        if (_session?.sid == sid) _session!.markPeerLeft();
      case RelayedFrame():
        if (_session?.sid == frame.sid) _session!.receive(frame);
      case ErrorFrame(:final code, :final message):
        _events.add(ServerErrorEvent(code, message));
      default:
        break;
    }
  }

  void _onClosed() {
    _closeChannel();
    _clearRequest();
    _session?.markPeerLeft();
    _fail('Connexion au serveur perdue.');
  }

  /// Records a failed attempt and retries with exponential backoff.
  void _fail(String reason) {
    _failures++;
    _lastError = reason;
    if (_disposed || _suspended) return;
    final factor = 1 << (_failures - 1).clamp(0, 10);
    final delay = reconnectDelay * factor;
    const max = Duration(seconds: kMaxReconnectDelaySeconds);
    final wait = delay > max ? max : delay;
    _nextRetryAt = DateTime.now().add(wait);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(wait, _open);
    _setStatus(ServerStatus.offline);
    notifyListeners();
  }

  static String _describe(Object error) {
    final text = error.toString().split('\n').first;
    return text.length > 160 ? '${text.substring(0, 160)}…' : text;
  }

  void _send(Frame frame) => _channel?.sink.add(frame.encode());

  void _setStatus(ServerStatus status) {
    if (_status == status || _disposed) return;
    _status = status;
    // Presence is only known while we are online ourselves.
    if (status != ServerStatus.online) _presence.clear();
    notifyListeners();
  }

  void _closeChannel() {
    _registerTimer?.cancel();
    _registerTimer = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    _subscription?.cancel();
    _subscription = null;
    _channel = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _requestTimer?.cancel();
    final channel = _channel;
    _closeChannel();
    channel?.sink.close();
    _session?.dispose();
    _events.close();
    super.dispose();
  }
}
