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
    'encoder' => 'L’encodage vidéo de cet appareil ne fonctionne pas.',
    _ => 'Caméra indisponible.',
  };

  @override
  Future<Set<String>> encoders() async {
    try {
      return {...?await _channel.invokeListMethod<String>('encoders')};
    } on PlatformException {
      return const {};
    } on MissingPluginException {
      return const {};
    }
  }

  @override
  Future<LiveCameraFrame?> nextFrame(LiveFrameRequest request) async {
    final Object? result;
    try {
      result = await _channel.invokeMethod<Object?>('frame', {
        'quality': request.quality,
        'side': request.side,
        'codec': ?request.codec,
        'kbps': request.kbps,
        'key': request.key,
        'preview': request.preview,
      });
    } on PlatformException catch (e) {
      throw LiveCameraException(_describe(e.code));
    }
    // JPEG: the bytes alone. Video: the access unit and what goes with it.
    if (result is Uint8List) return LiveCameraFrame(result);
    if (result is! Map) return null;
    final data = result['data'];
    if (data is! Uint8List || data.isEmpty) return null;
    final rotation = result['rot'];
    final preview = result['preview'];
    return LiveCameraFrame(
      data,
      key: result['key'] == true,
      rotation: rotation is int ? rotation : 0,
      preview: preview is Uint8List ? preview : null,
    );
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
