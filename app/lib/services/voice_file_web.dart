import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

/// The browser records into memory: no path is needed.
Future<String> newVoicePath(String extension) async => '';

/// [url] is the blob URL returned by the recorder.
Future<({Uint8List bytes, String? mime})?> readVoiceFile(String url) async {
  try {
    final response = await web.window.fetch(url.toJS).toDart;
    final blob = await response.blob().toDart;
    final buffer = await blob.arrayBuffer().toDart;
    return (bytes: buffer.toDart.asUint8List(), mime: blob.type);
  } finally {
    web.URL.revokeObjectURL(url);
  }
}
