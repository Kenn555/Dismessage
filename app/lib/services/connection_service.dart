import 'dart:async';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'chat_session.dart';
import 'file_storage.dart';
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

/// The peer's encryption key never came: the conversation was closed
/// rather than sent in clear.
class EncryptionFailedEvent extends ConnectionEvent {
  const EncryptionFailedEvent(this.peer);
  final String peer;
}

class ServerErrorEvent extends ConnectionEvent {
  const ServerErrorEvent(this.code, this.message);
  final String code;
  final String message;
}

typedef ChannelFactory = WebSocketChannel Function(Uri uri);

/// End-to-end encryption of one conversation, with its frames kept in
/// order through the asynchronous sealing and opening.
class _Secure {
  _Secure(String sid) : e2e = E2eSession(sid);
  final E2eSession e2e;
  Future<void> outgoing = Future.value();
  Future<void> incoming = Future.value();
  Timer? handshake;
}

/// Keeps the connection to the relay alive and dispatches its frames.
class ConnectionService extends ChangeNotifier {
  ConnectionService({
    required IdentityService identity,
    required Uri serverUri,
    ChannelFactory? connect,
    this.reconnectDelay = const Duration(seconds: 2),
    this.connectTimeout = const Duration(seconds: kConnectTimeoutSeconds),
    FileStorage? fileStorage,
    bool Function(String from)? acceptsRequestFrom,
  }) : _acceptsRequestFrom = acceptsRequestFrom,
       _identity = identity,
       _serverUri = serverUri,
       _connect = connect ?? WebSocketChannel.connect,
       _fileStorage = fileStorage;

  final IdentityService _identity;

  /// Filters incoming chat requests (blocked IDs, "contacts only"): a
  /// refused one is dropped without answer, no dialog, no notification.
  final bool Function(String from)? _acceptsRequestFrom;

  /// Where received files go (the platform's downloads when null).
  final FileStorage? _fileStorage;
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

  /// An `id_request` is out: the next `id_assigned` is ours.
  bool _awaitingId = false;
  final Map<String, ChatSession> _sessions = {};
  final Map<String, _Secure> _secure = {};
  ChatSession? _active;
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

  /// Open conversations, oldest first (ended ones stay until closed).
  List<ChatSession> get sessions => List.unmodifiable(_sessions.values);

  /// Whether [session] is end-to-end encrypted yet (keys exchanged).
  bool isEncrypted(ChatSession session) =>
      _secure[session.sid]?.e2e.isReady ?? false;

  /// The code both people can compare to rule out an interception by the
  /// relay; null until the keys are exchanged.
  Future<String?> safetyCode(ChatSession session) async =>
      await _secure[session.sid]?.e2e.safetyCode();

  /// The conversation on screen, if any.
  ChatSession? get active => _active;

  /// The live conversation with [peer], if any.
  ChatSession? liveSessionWith(String peer) {
    for (final session in _sessions.values) {
      if (session.peer == peer && !session.peerLeft) return session;
    }
    return null;
  }

  /// Shows [session] (null: none, back to the home screen). Its unread
  /// bubbles are then read.
  void activate(ChatSession? session) {
    if (session != null && _sessions[session.sid] != session) return;
    if (session == _active) return;
    _active?.viewing = false;
    _active = session;
    session?.viewing = true;
    notifyListeners();
  }

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
    _me ??= _identity.load(_serverUri);
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

  /// Closes [session] (the peer is notified if still there). The most
  /// recent remaining conversation is shown if it was on screen.
  void closeSession(ChatSession session) {
    if (_sessions[session.sid] != session) return;
    _remove(session);
    if (_active == session) {
      _active = null;
      if (_sessions.isNotEmpty) {
        _active = _sessions.values.last..viewing = true;
      }
    }
    notifyListeners();
  }

  /// Closes every conversation.
  void closeAll() {
    if (_sessions.isEmpty) return;
    for (final session in _sessions.values.toList()) {
      _remove(session);
    }
    _active = null;
    notifyListeners();
  }

  void _remove(ChatSession session) {
    _sessions.remove(session.sid);
    if (!session.peerLeft) _send(SessionLeaveFrame(sid: session.sid));
    _forgetKeys(session.sid);
    session.dispose();
  }

  /// The conversation's keys only live as long as it does.
  void _forgetKeys(String sid) => _secure.remove(sid)?.handshake?.cancel();

  /// Conversation frames are sealed, in order, once the keys are exchanged;
  /// nothing leaves unencrypted.
  void _sendInSession(String sid, Frame frame) {
    final secure = _secure[sid];
    if (frame is! RelayedFrame) return _send(frame);
    if (secure == null) return;
    secure.outgoing = secure.outgoing.then((_) async {
      final sealed = await secure.e2e.seal(frame);
      if (_secure[sid] == secure) _send(sealed);
    });
  }

  /// Runs [action] after the frames already received for [sid], in order.
  void _inOrder(String sid, FutureOr<void> Function(_Secure secure) action) {
    final secure = _secure[sid];
    if (secure == null) return;
    secure.incoming = secure.incoming.then((_) => action(secure));
  }

  void _markAllPeerLeft() {
    for (final session in _sessions.values) {
      session.markPeerLeft();
    }
  }

  /// Switches to a brand new ID, given by the relay (online only); the old
  /// one is released once the new one is registered.
  Future<void> regenerateId() async {
    if (_status != ServerStatus.online) return;
    closeAll();
    _pendingRelease ??= _me;
    _requestId();
  }

  /// Asks the relay for a new ID (none yet, or ours was refused).
  void _requestId() {
    _awaitingId = true;
    _send(const IdRequestFrame());
    _startRegisterTimer();
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
    _markAllPeerLeft();
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
    // Each relay has its own identity (it signs the secrets it gives).
    _me = _identity.load(uri);
    _pendingRelease = null;
    _awaitingId = false;
    _reconnectTimer?.cancel();
    _clearRequest();
    final channel = _channel;
    _closeChannel();
    _markAllPeerLeft();
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
    final me = _me;
    if (me == null) return _requestId();
    _send(RegisterFrame(id: me.id, secret: me.secret));
    _startRegisterTimer();
  }

  void _startRegisterTimer() {
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
      case IdAssignedFrame(:final id, :final secret)
          when _awaitingId || id == _me?.id:
        // A new ID, or ours now signed (registered right after): kept.
        final identity = Identity(id: id, secret: secret);
        final isNew = _awaitingId;
        _awaitingId = false;
        _me = identity;
        await _identity.save(_serverUri, identity);
        if (isNew) _register();
        notifyListeners();
      case IdTakenFrame(:final id) when id == _me?.id:
        // Someone else owns this ID on the relay: ask it for a new one.
        _requestId();
      case ErrorFrame(:final code)
          when code == ErrorCodes.unsignedId && _status != ServerStatus.online:
        // Our own ID (older version), unknown to this relay: get one.
        _requestId();
      case IncomingRequestFrame(:final from):
        if (_acceptsRequestFrom?.call(from) ?? true) {
          _events.add(IncomingRequestEvent(from));
        }
      case SessionStartedFrame(:final sid, :final peer):
        _clearRequest();
        _startSession(sid, peer);
      case PeerOfflineFrame(:final peer):
        _clearRequest(peer);
        _events.add(PeerOfflineEvent(peer));
      case ConnectRejectFrame(:final peer):
        _clearRequest(peer);
        _events.add(RequestRejectedEvent(peer));
      case ConnectCancelFrame(:final peer):
        _events.add(RequestCancelledEvent(peer));
      case PeerLeftFrame(:final sid):
        // After the frames still being opened.
        if (_secure.containsKey(sid)) {
          _inOrder(sid, (_) => _sessions[sid]?.markPeerLeft());
        } else {
          _sessions[sid]?.markPeerLeft();
        }
      case KeyOfferFrame(:final sid) && final offer:
        _inOrder(sid, (secure) async {
          try {
            await secure.e2e.accept(offer);
            secure.handshake?.cancel();
            notifyListeners();
          } on E2eException {
            // A second or invalid key: the first one stays.
          }
        });
      case SealedFrame(:final sid) && final sealed:
        _inOrder(sid, (secure) async {
          try {
            final inner = await secure.e2e.open(sealed);
            if (_secure[sid] == secure) _sessions[sid]?.receive(inner);
          } on E2eException {
            // Altered, replayed or not from the peer: dropped.
          }
        });
      case RelayedFrame():
        // Unencrypted conversation frame: never trusted.
        break;
      case ErrorFrame(:final code, :final message)
          when _status != ServerStatus.online &&
              (code == ErrorCodes.rateLimited ||
                  code == ErrorCodes.tooManyConnections ||
                  code == ErrorCodes.updateRequired):
        // Registration refused: retry later, and show why on the home screen.
        _registerTimer?.cancel();
        final channel = _channel;
        _closeChannel();
        channel?.sink.close();
        _fail(message);
      case ErrorFrame(:final code, :final message):
        // A refused chat request gets no answer: stop waiting for one.
        if (code == ErrorCodes.rateLimited) _clearRequest();
        _events.add(ServerErrorEvent(code, message));
      default:
        break;
    }
  }

  /// Opens a conversation and shows it. An older one with the same peer
  /// (ended, or crossed requests) is replaced in place.
  void _startSession(String sid, String peer) {
    final secure = _secure[sid] = _Secure(sid);
    // Our key first: every later frame of ours waits for the peer's.
    secure.outgoing = secure.e2e.offer().then(_send);
    final session = ChatSession(
      sid: sid,
      peer: peer,
      send: (frame) => _sendInSession(sid, frame),
      files: _fileStorage,
    );
    secure.handshake = Timer(const Duration(seconds: kE2eHandshakeSeconds), () {
      if (_sessions[sid] != session || secure.e2e.isReady) return;
      closeSession(session);
      _events.add(EncryptionFailedEvent(peer));
    });
    final previous = _sessions.values.where((s) => s.peer == peer).toList();
    if (previous.isEmpty) {
      _sessions[sid] = session;
    } else {
      final old = previous.first;
      final entries = _sessions.entries.toList();
      _sessions.clear();
      for (final MapEntry(:key, :value) in entries) {
        if (value == old) {
          _sessions[sid] = session;
        } else if (!previous.contains(value)) {
          _sessions[key] = value;
        }
      }
      for (final stale in previous) {
        if (!stale.peerLeft) _send(SessionLeaveFrame(sid: stale.sid));
        if (_active == stale) _active = null;
        _forgetKeys(stale.sid);
        stale.dispose();
      }
    }
    _active?.viewing = false;
    _active = session..viewing = true;
    notifyListeners();
    _events.add(SessionStartedEvent(session));
  }

  void _onClosed() {
    _closeChannel();
    _clearRequest();
    _markAllPeerLeft();
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
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
    for (final sid in _secure.keys.toList()) {
      _forgetKeys(sid);
    }
    _events.close();
    super.dispose();
  }
}
