import 'dart:io';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'live_picture.dart';
import 'live_video.dart';

LiveVideoCodecs createLiveVideoCodecs() =>
    Platform.isWindows || Platform.isAndroid
    ? const ChannelLiveVideoCodecs()
    : const NoLiveVideo();

/// The runner's video decoders, through the `dismessage/video` channel:
/// Media Foundation on Windows, MediaCodec on Android. Both draw into a
/// Flutter texture: the image never goes through Dart.
class ChannelLiveVideoCodecs implements LiveVideoCodecs {
  const ChannelLiveVideoCodecs();

  static const channel = MethodChannel('dismessage/video');
  static Set<String>? _decoders;

  @override
  Future<Set<String>> decoders() {
    final known = _decoders;
    if (known != null) return SynchronousFuture(known);
    return _ask();
  }

  static Future<Set<String>> _ask() async {
    try {
      final list = await channel.invokeListMethod<String>('decoders');
      return _decoders = {...?list};
    } on PlatformException {
      return const {};
    } on MissingPluginException {
      return const {};
    }
  }

  @override
  LiveVideoDecoder? create(String codec) => _ChannelDecoder(codec);
}

class _ChannelDecoder implements LiveVideoDecoder {
  _ChannelDecoder(this._codec);

  final String _codec;
  Future<int>? _id;
  bool _closed = false;

  Future<int> _create() async {
    final id = await ChannelLiveVideoCodecs.channel.invokeMethod<int>(
      'create',
      {'codec': _codec},
    );
    if (id == null) throw StateError('no decoder');
    return id;
  }

  @override
  Future<LivePicture?> decode(
    Uint8List data, {
    required bool key,
    required int rotation,
  }) async {
    if (_closed) return null;
    final id = await (_id ??= _create());
    final result = await ChannelLiveVideoCodecs.channel
        .invokeMapMethod<String, Object?>('decode', {
          'id': id,
          'data': data,
          'key': key,
        });
    if (result == null || _closed) return null;
    final width = result['w'], height = result['h'];
    if (width is! int ||
        height is! int ||
        width <= 0 ||
        height <= 0 ||
        width > kLiveMaxDecodedSide ||
        height > kLiveMaxDecodedSide) {
      throw StateError('bad size');
    }
    final texture = result['texture'];
    if (texture is! int) return null;
    return LivePicture.texture(
      texture,
      width: width,
      height: height,
      rotation: rotation,
    );
  }

  @override
  Future<void> close() async {
    _closed = true;
    final pending = _id;
    _id = null;
    if (pending == null) return;
    try {
      final id = await pending;
      await ChannelLiveVideoCodecs.channel.invokeMethod<void>('close', {
        'id': id,
      });
    } catch (_) {
      // Never created, or already gone.
    }
  }
}
