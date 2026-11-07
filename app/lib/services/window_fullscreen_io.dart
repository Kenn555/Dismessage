import 'dart:io';

import 'package:flutter/services.dart';

const _overlayChannel = MethodChannel('dismessage/overlay');

/// Windows: the runner covers the screen (`overlay.cpp`). Android: the system
/// bars hide.
Future<void> platformSetFullscreen(bool on) async {
  try {
    if (Platform.isWindows) {
      await _overlayChannel.invokeMethod<void>('fullscreen', {
        'on': on ? 1 : 0,
      });
    } else if (Platform.isAndroid) {
      await SystemChrome.setEnabledSystemUIMode(
        on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
    }
  } on PlatformException {
    // The view still fills the window.
  } on MissingPluginException {
    // Same (tests).
  }
}
