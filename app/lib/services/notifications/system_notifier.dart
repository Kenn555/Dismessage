import 'system_notifier_io.dart'
    if (dart.library.js_interop) 'system_notifier_web.dart'
    as platform;

/// A button of a notification (e.g. « Accepter »).
class NoticeAction {
  const NoticeAction(this.id, this.label, {this.foreground = false});
  final String id;
  final String label;

  /// Also brings the app to the front (e.g. accepting opens the chat).
  final bool foreground;
}

/// One notification (a conversation, or a request), replaced as it changes.
class ChatNotice {
  const ChatNotice({
    required this.tag,
    required this.title,
    required this.lines,
    required this.alert,
    required this.canReply,
    this.actions = const [],
  });

  /// Identifies the notification to replace (the session id, or the
  /// requester for a request).
  final String tag;

  /// Contact name or formatted ID.
  final String title;

  /// Unread messages, then what the peer is typing.
  final List<String> lines;

  /// Sound and pop-up; false for a silent update (typing in progress).
  final bool alert;

  /// Offer a reply field (where the platform has one).
  final bool canReply;

  /// Buttons (where the platform has them).
  final List<NoticeAction> actions;

  String get body => lines.join('\n');
}

/// What the user did with a notification.
abstract class NotifierCallbacks {
  /// Text typed in the notification's reply field.
  void onReply(String tag, String text);

  /// Notification tapped: the app is brought to the front.
  void onOpen(String tag);

  /// One of the notification's buttons was pressed.
  void onAction(String tag, String action);
}

/// System notifications of the current platform.
abstract class SystemNotifier {
  /// Starts receiving the user's actions.
  void listen(NotifierCallbacks callbacks);

  /// Asks for the right to notify (Android 13+, browsers). True if granted.
  Future<bool> requestPermission();

  /// Whether this platform shows a reply field and buttons in
  /// notifications.
  bool get supportsReply;

  Future<void> show(ChatNotice notice);

  Future<void> cancel(String tag);
}

/// Does nothing: platforms without notifications, and tests by default.
class SilentNotifier implements SystemNotifier {
  const SilentNotifier();
  @override
  void listen(NotifierCallbacks callbacks) {}
  @override
  Future<bool> requestPermission() async => false;
  @override
  bool get supportsReply => false;
  @override
  Future<void> show(ChatNotice notice) async {}
  @override
  Future<void> cancel(String tag) async {}
}

SystemNotifier platformNotifier() => platform.createNotifier();
