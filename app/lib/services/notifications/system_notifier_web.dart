import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'system_notifier.dart';

SystemNotifier createNotifier() => WebNotifier();

/// Browser notifications. Browsers offer no reply field: a click brings the
/// conversation back.
class WebNotifier implements SystemNotifier {
  final Map<String, web.Notification> _shown = {};
  NotifierCallbacks? _callbacks;

  static bool get _available =>
      web.window.has('Notification') && web.window.isSecureContext;

  @override
  void listen(NotifierCallbacks callbacks) => _callbacks = callbacks;

  @override
  Future<bool> requestPermission() async {
    if (!_available) return false;
    if (web.Notification.permission == 'granted') return true;
    if (web.Notification.permission == 'denied') return false;
    try {
      final answer = await web.Notification.requestPermission().toDart;
      return answer.toDart == 'granted';
    } catch (_) {
      return false;
    }
  }

  @override
  bool get supportsReply => false;

  @override
  Future<void> show(ChatNotice notice) async {
    if (!_available || web.Notification.permission != 'granted') return;
    final notification = web.Notification(
      notice.title,
      web.NotificationOptions(
        body: notice.body,
        tag: notice.tag,
        icon: 'icons/Icon-192.png',
        // Same tag: replaces the previous one; only alert for new messages.
        renotify: notice.alert,
        silent: !notice.alert,
      ),
    );
    notification.onclick = ((web.Event _) {
      web.window.focus();
      notification.close();
      _callbacks?.onOpen(notice.tag);
    }).toJS;
    _shown[notice.tag] = notification;
  }

  @override
  Future<void> cancel(String tag) async => _shown.remove(tag)?.close();
}
