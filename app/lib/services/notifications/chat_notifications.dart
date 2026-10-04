import 'dart:async';

import 'package:dismessage_protocol/dismessage_protocol.dart';

import '../chat_session.dart';
import '../connection_service.dart';
import '../contacts_service.dart';
import 'system_notifier.dart';

/// Notifies messages and typing the user cannot see, and sends the replies
/// typed in those notifications.
///
/// Nothing is notified while the app is visible ([appVisible]); coming back
/// clears the conversation's notification.
class ChatNotifications implements NotifierCallbacks {
  ChatNotifications({
    required ConnectionService connection,
    required ContactsService contacts,
    required SystemNotifier notifier,
    Duration typingDelay = const Duration(milliseconds: kTypingNotificationMs),
  }) : _connection = connection,
       _contacts = contacts,
       _notifier = notifier,
       _typingDelay = typingDelay {
    _notifier.listen(this);
    _connection.addListener(_onConnection);
    _events = _connection.events.listen(_onEvent);
    _onConnection();
    // Asked at startup: a request can come before any conversation.
    _notifier.requestPermission();
  }

  final ConnectionService _connection;
  final ContactsService _contacts;
  final SystemNotifier _notifier;
  final Duration _typingDelay;

  late final StreamSubscription<ConnectionEvent> _events;
  ChatSession? _session;
  bool _visible = true;

  /// Requesters whose request is notified.
  final Set<String> _requests = {};

  /// Bubbles of the session already accounted for.
  int _seen = 0;

  /// Unread messages, oldest first (at most [kNotificationMaxLines]).
  final List<String> _unread = [];

  /// Typing already announced with a sound for the current burst.
  bool _typingAnnounced = false;
  String _shownDraft = '';
  DateTime? _lastTypingUpdate;
  Timer? _typingTimer;
  bool _shown = false;

  /// Whether the user currently sees the app (foreground, focused).
  bool get appVisible => _visible;
  set appVisible(bool visible) {
    if (_visible == visible) return;
    _visible = visible;
    final session = _session;
    if (visible) {
      _clear();
      if (session != null) _seen = session.messages.length;
      // The request dialogs are on screen now.
      for (final from in _requests.toList()) {
        _cancelRequest(from);
      }
    }
  }

  static const _requestPrefix = 'request-';

  void _onEvent(ConnectionEvent event) {
    switch (event) {
      case IncomingRequestEvent(:final from):
        if (_visible) return;
        _requests.add(from);
        _notifier.show(
          ChatNotice(
            tag: '$_requestPrefix$from',
            title: 'Demande de conversation',
            // A contact by name; an unknown person by full ID.
            lines: ['${_contacts.label(from)} veut discuter avec vous.'],
            alert: true,
            canReply: false,
            actions: const [
              NoticeAction('accept', 'Accepter', foreground: true),
              NoticeAction('reject', 'Refuser'),
            ],
          ),
        );
      case RequestCancelledEvent(:final from):
        _cancelRequest(from);
      case IncomingRequestAnsweredEvent(:final from):
        _cancelRequest(from);
      default:
        break;
    }
  }

  void _cancelRequest(String from) {
    if (_requests.remove(from)) _notifier.cancel('$_requestPrefix$from');
  }

  void _onConnection() {
    final session = _connection.session;
    if (session == _session) return;
    _clear();
    _session?.removeListener(_onSession);
    _session = session;
    if (session == null) return;
    _seen = session.messages.length;
    session.addListener(_onSession);
  }

  void _onSession() {
    final session = _session;
    if (session == null) return;
    final entries = session.messages;
    final fresh = entries.skip(_seen).where((e) => !e.fromMe).toList();
    _seen = entries.length;
    if (_visible) return;

    if (fresh.isNotEmpty) {
      for (final entry in fresh) {
        _unread.add(_snippet(entry));
      }
      while (_unread.length > kNotificationMaxLines) {
        _unread.removeAt(0);
      }
      // A message ends the typing burst: the next one is announced again.
      _typingAnnounced = false;
      _shownDraft = session.remoteDraft;
      _show(alert: true);
      return;
    }

    final draft = session.remoteDraft;
    if (draft == _shownDraft) return;
    if (draft.isEmpty) {
      // Typing erased or stopped without sending.
      _typingAnnounced = false;
      _shownDraft = '';
      _typingTimer?.cancel();
      if (_unread.isEmpty) {
        _cancel();
      } else {
        _show(alert: false);
      }
      return;
    }
    if (!_typingAnnounced) {
      _typingAnnounced = true;
      _shownDraft = draft;
      _show(alert: true);
      return;
    }
    // Silent, throttled updates of the live text.
    final last = _lastTypingUpdate;
    final wait = last == null
        ? Duration.zero
        : _typingDelay - DateTime.now().difference(last);
    if (wait <= Duration.zero) {
      _shownDraft = draft;
      _show(alert: false);
    } else {
      _typingTimer ??= Timer(wait, () {
        _typingTimer = null;
        final current = _session?.remoteDraft ?? '';
        if (!_visible && current.isNotEmpty && current != _shownDraft) {
          _shownDraft = current;
          _show(alert: false);
        }
      });
    }
  }

  void _show({required bool alert}) {
    final session = _session;
    if (session == null) return;
    final draft = session.remoteDraft;
    final lines = [
      ..._unread,
      if (draft.isNotEmpty) '✍️ ${_shorten(draft.replaceAll('\n', ' '))}',
    ];
    if (lines.isEmpty) return;
    if (draft.isNotEmpty) _lastTypingUpdate = DateTime.now();
    _shown = true;
    final name = _contacts.byId(session.peer)?.name;
    final who = name ?? DismessageId.format(session.peer);
    _notifier.show(
      ChatNotice(
        tag: session.sid,
        // While typing without anything unread, say it in the title.
        title: _unread.isEmpty && draft.isNotEmpty
            ? '$who est en train d’écrire…'
            : who,
        lines: lines,
        alert: alert,
        canReply: !session.peerLeft && _notifier.supportsReply,
      ),
    );
  }

  static String _snippet(ChatEntry entry) => _shorten(switch (entry) {
    ChatMessage(:final text) => text.replaceAll(RegExp(r'\s+'), ' ').trim(),
    ChatImage() => '📷 Photo',
    ChatVoice() => '🎤 Message vocal',
  });

  static String _shorten(String text) => text.length <= kNotificationLineLength
      ? text
      : '${text.substring(0, kNotificationLineLength)}…';

  @override
  void onReply(String tag, String text) {
    final session = _session;
    if (session == null || session.sid != tag) {
      _notifier.cancel(tag);
      return;
    }
    session.sendQuickReply(text);
    // Answered: the unread messages are read.
    _seen = session.messages.length;
    _clear();
  }

  @override
  void onOpen(String tag) {
    if (tag.startsWith(_requestPrefix)) return;
    _clear();
  }

  @override
  void onAction(String tag, String action) {
    if (!tag.startsWith(_requestPrefix)) return;
    final from = tag.substring(_requestPrefix.length);
    switch (action) {
      case 'accept':
        _connection.accept(from);
      case 'reject':
        _connection.reject(from);
    }
    // The answered event removes the notification.
  }

  void _cancel() {
    final session = _session;
    _typingTimer?.cancel();
    _typingTimer = null;
    if (_shown && session != null) _notifier.cancel(session.sid);
    _shown = false;
  }

  void _clear() {
    _unread.clear();
    _typingAnnounced = false;
    _shownDraft = '';
    _lastTypingUpdate = null;
    _cancel();
  }

  void dispose() {
    _events.cancel();
    _clear();
    _session?.removeListener(_onSession);
    _connection.removeListener(_onConnection);
  }
}
