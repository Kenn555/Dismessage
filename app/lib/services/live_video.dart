import 'package:flutter/foundation.dart';

import 'live_picture.dart';
import 'live_video_io.dart'
    if (dart.library.js_interop) 'live_video_web.dart'
    as platform;

/// Decodes the peer's live video, one access unit after the other, in order.
abstract class LiveVideoDecoder {
  /// Decodes [data]; the picture to show now, or null when nothing is ready
  /// yet. Throws when the stream cannot be decoded: a new decoder then
  /// starts again from a key frame.
  Future<LivePicture?> decode(
    Uint8List data, {
    required bool key,
    required int rotation,
  });

  Future<void> close();
}

/// The video decoders of this device.
abstract class LiveVideoCodecs {
  /// The codecs it can decode ([kLiveCodecH264]…); empty when none. A
  /// [SynchronousFuture] once known, so that a request leaves at once.
  Future<Set<String>> decoders();

  /// A decoder for [codec], or null.
  LiveVideoDecoder? create(String codec);
}

/// No video: JPEG only.
class NoLiveVideo implements LiveVideoCodecs {
  const NoLiveVideo();
  @override
  Future<Set<String>> decoders() => SynchronousFuture(const {});
  @override
  LiveVideoDecoder? create(String codec) => null;
}

LiveVideoCodecs platformLiveVideo() => platform.createLiveVideoCodecs();
