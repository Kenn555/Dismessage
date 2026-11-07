import 'package:flutter/foundation.dart';

import 'identity_service.dart';
import 'media_devices_io.dart'
    if (dart.library.js_interop) 'media_devices_web.dart'
    as platform;

/// A camera or a microphone of this device.
class MediaDevice {
  const MediaDevice({required this.id, required this.label});

  /// What the platform knows it by.
  final String id;
  final String label;
}

/// Lists the cameras and microphones; injected in tests.
abstract class MediaDeviceLister {
  Future<List<MediaDevice>> cameras();
  Future<List<MediaDevice>> microphones();
}

/// The lister of this platform.
MediaDeviceLister platformMediaDevices() => platform.createMediaDeviceLister();

/// The camera and microphone chosen in the settings; none means the system's
/// default. Kept on this device only. A device that is gone is ignored by the
/// platforms, which then use the default one.
class DevicePreferences extends ChangeNotifier {
  DevicePreferences(this._store, {MediaDeviceLister? lister})
    : lister = lister ?? platformMediaDevices();

  static const cameraKey = 'dismessage.camera';
  static const microphoneKey = 'dismessage.microphone';

  final KeyValueStore _store;
  final MediaDeviceLister lister;

  String? get cameraId => _read(cameraKey);
  String? get microphoneId => _read(microphoneKey);

  String? _read(String key) {
    final value = _store.getString(key);
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> setCamera(String? id) => _write(cameraKey, id);
  Future<void> setMicrophone(String? id) => _write(microphoneKey, id);

  Future<void> _write(String key, String? id) async {
    await _store.setString(key, id ?? '');
    notifyListeners();
  }
}
