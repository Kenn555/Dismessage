import 'dart:io';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/services.dart';

import 'live_camera.dart';

LiveCamera? createLiveCamera(String? deviceId) =>
    Platform.isWindows || Platform.isAndroid
    ? ChannelLiveCamera(deviceId)
    : null;

/// The runner's camera, through the `dismessage/camera` channel.
class ChannelLiveCamera implements LiveCamera {
  ChannelLiveCamera(this._deviceId);

  static const _channel = MethodChannel('dismessage/camera');
  final String? _deviceId;

  @override
  Future<void> open() async {
    try {
      await _channel.invokeMethod<void>('open', {
        'side': kLiveMaxSide,
        'device': ?_deviceId,
      });
    } on PlatformException catch (e) {
      throw LiveCameraException(_describe(e.code));
    } on MissingPluginException {
      throw const LiveCameraException('Caméra indisponible.');
    }
  }

  /// The runners give a code, the words are here.
  static String _describe(String code) => switch (code) {
    'no_camera' => 'Aucune caméra détectée.',
    'denied' =>
      'Accès à la caméra refusé : autorisez-le dans les réglages de '
          'confidentialité de cet appareil.',
    'busy' => 'La caméra est utilisée par une autre application.',
    'stopped' => 'La caméra s’est arrêtée.',
    _ => 'Caméra indisponible.',
  };

  @override
  Future<Uint8List?> nextFrame(int quality, int side) async {
    try {
      return await _channel.invokeMethod<Uint8List>('frame', {
        'quality': quality,
        'side': side,
      });
    } on PlatformException catch (e) {
      throw LiveCameraException(_describe(e.code));
    }
  }

  @override
  Future<void> setCaptureSide(int side) async {
    try {
      await _channel.invokeMethod<void>('capture', {'side': side});
    } on PlatformException {
      // The frames stay at their size.
    }
  }

  @override
  Future<void> close() async {
    try {
      await _channel.invokeMethod<void>('close');
    } on PlatformException {
      // Already off.
    } on MissingPluginException {
      // Never opened.
    }
  }
}
