import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'media_devices.dart';

MediaDeviceLister createMediaDeviceLister() => _BrowserMediaDevices();

/// The browser hides the names until the camera or microphone has been
/// allowed once: they are numbered until then.
class _BrowserMediaDevices implements MediaDeviceLister {
  Future<List<MediaDevice>> _list(String kind, String fallback) async {
    try {
      final devices = await web.window.navigator.mediaDevices
          .enumerateDevices()
          .toDart;
      final found = devices.toDart.where(
        (d) => d.kind == kind && d.deviceId.isNotEmpty,
      );
      var number = 0;
      return [
        for (final device in found)
          MediaDevice(
            id: device.deviceId,
            label: device.label.isEmpty
                ? '$fallback ${++number}'
                : device.label,
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<MediaDevice>> cameras() => _list('videoinput', 'Caméra');

  @override
  Future<List<MediaDevice>> microphones() => _list('audioinput', 'Micro');
}
