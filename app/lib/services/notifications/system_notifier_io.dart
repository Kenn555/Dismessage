import 'dart:io';

import 'package:flutter/services.dart';

import 'system_notifier.dart';

/// Android (`NotificationHandler.kt`) and Windows (`notifications.cpp`)
/// share the same channel.
SystemNotifier createNotifier() => Platform.isAndroid || Platform.isWindows
    ? ChannelNotifier()
    : const SilentNotifier();

class ChannelNotifier implements SystemNotifier {
  static const _channel = MethodChannel('dismessage/notify');

  @override
  void listen(NotifierCallbacks callbacks) {
    _channel.setMethodCallHandler((call) async {
      final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
      final tag = args['tag'] as String? ?? '';
      switch (call.method) {
        case 'onReply':
          callbacks.onReply(tag, args['text'] as String? ?? '');
        case 'onOpen':
          callbacks.onOpen(tag);
      }
    });
  }

  @override
  Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  bool get supportsReply => true;

  @override
  Future<void> show(ChatNotice notice) => _call('show', {
    'tag': notice.tag,
    'title': notice.title,
    'body': notice.body,
    'lines': notice.lines,
    'alert': notice.alert,
    'reply': notice.canReply,
  });

  @override
  Future<void> cancel(String tag) => _call('cancel', {'tag': tag});

  /// A notification that fails must never break the conversation.
  static Future<void> _call(String method, Map<String, Object?> args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on PlatformException {
      // Notifications disabled or unavailable: nothing to do.
    } on MissingPluginException {
      // Runner built without the channel (e.g. tests).
    }
  }
}
