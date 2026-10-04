import 'system_notifier_io.dart'
    if (dart.library.js_interop) 'system_notifier_web.dart'
    as platform;

/// One conversation's notification, replaced as it changes.
class ChatNotice {
  const ChatNotice({
    required this.tag,
    required this.title,
    required this.lines,
    required this.alert,
    required this.canReply,
  });

  /// Identifies the notification to replace (the session id).
  final String tag;

  /// Contact name or formatted ID.
  final String title;

  /// Unread messages, then what the peer is typing.
  final List<String> lines;

  /// Sound and pop-up; false for a silent update (typing in progress).
  final bool alert;

  /// Offer a reply field (where the platform has one).
  final bool canReply;

  String get body => lines.join('\n');
}

/// What the user did with a notification.
abstract class NotifierCallbacks {
  /// Text typed in the notification's reply field.
  void onReply(String tag, String text);

  /// Notification tapped: the app is brought to the front.
  void onOpen(String tag);
}

/// System notifications of the current platform.
abstract class SystemNotifier {
  /// Starts receiving the user's actions.
  void listen(NotifierCallbacks callbacks);

  /// Asks for the right to notify (Android 13+, browsers). True if granted.
  Future<bool> requestPermission();

  /// Whether this platform shows a reply field in notifications.
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
