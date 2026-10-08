import 'dart:io';

import 'package:flutter/services.dart';

/// Android: an `ACTION_VIEW` intent through the files channel
/// (`FileHandler.kt`), so no `url_launcher` and its Gradle dependencies.
/// Desktop: the system opener.
Future<bool> openLink(Uri url) async {
  try {
    if (Platform.isAndroid) {
      return await const MethodChannel(
            'dismessage/files',
          ).invokeMethod<bool>('openUrl', {'url': url.toString()}) ??
          false;
    }
    final (command, args) = switch (Platform.operatingSystem) {
      'windows' => ('explorer.exe', [url.toString()]),
      'macos' => ('open', [url.toString()]),
      _ => ('xdg-open', [url.toString()]),
    };
    await Process.start(command, args, mode: ProcessStartMode.detached);
    return true;
  } on Exception {
    return false;
  }
}
