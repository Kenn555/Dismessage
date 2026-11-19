import 'dart:io';

import 'package:flutter/services.dart';
import 'package:record_platform_interface/record_platform_interface.dart';

import 'media_devices.dart';
import 'recorder_pool.dart';

MediaDeviceLister createMediaDeviceLister() => _NativeMediaDevices();

class _NativeMediaDevices implements MediaDeviceLister {
  static const _camera = MethodChannel('dismessage/camera');
  static const _voice = MethodChannel('dismessage/voice');

  static Future<List<MediaDevice>> _list(
    MethodChannel channel,
    String method,
  ) async {
    try {
      final devices = await channel.invokeListMethod<Map<Object?, Object?>>(
        method,
      );
      return [
        for (final device in devices ?? const <Map<Object?, Object?>>[])
          MediaDevice(
            id: device['id']! as String,
            label: device['label']! as String,
          ),
      ];
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  @override
  Future<List<MediaDevice>> cameras() => _list(_camera, 'list');

  @override
  Future<List<MediaDevice>> microphones() async {
    if (Platform.isAndroid) return _list(_voice, 'listInputs');
    // Windows: the recorder plugin, through a recorder of its own.
    final record = RecordPlatform.instance;
    String? id;
    try {
      id = await RecorderPool.take();
      final devices = await record.listInputDevices(id);
      return [
        for (final device in devices)
          MediaDevice(id: device.id, label: device.label),
      ];
    } catch (_) {
      return const [];
    } finally {
      // Never disposed: see RecorderPool.
      if (id != null) await RecorderPool.give(id);
    }
  }
}
