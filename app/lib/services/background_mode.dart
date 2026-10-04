import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'identity_service.dart';

/// Android only: stay connected with the screen closed and start with the
/// phone (`BackgroundService.kt`), so messages, typing and requests are
/// still notified. Off by default; Windows has the same option in its
/// installer.
class BackgroundMode extends ChangeNotifier {
  BackgroundMode(this._store, {bool? supported, MethodChannel? channel})
    : supported =
          supported ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.android),
      _channel = channel ?? const MethodChannel('dismessage/background');

  /// Read by the native side too (BootReceiver), as `flutter.<key>`.
  static const key = 'dismessage.background';

  final KeyValueStore _store;
  final MethodChannel _channel;
  final bool supported;

  bool get enabled => supported && _store.getString(key) == 'true';

  Future<void> setEnabled(bool value) async {
    if (!supported) return;
    await _store.setString(key, '$value');
    notifyListeners();
    try {
      await _channel.invokeMethod<void>('setEnabled', value);
    } on PlatformException {
      // Service refused by the system: it starts at the next opening.
    } on MissingPluginException {
      // Tests.
    }
  }
}
