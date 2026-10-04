import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// A temporary file for a new recording.
Future<String> newVoicePath(String extension) async {
  final dir = await getTemporaryDirectory();
  final stamp = DateTime.now().microsecondsSinceEpoch;
  return '${dir.path}${Platform.pathSeparator}dismessage_voice_$stamp.$extension';
}

/// Reads the recording, then deletes it: voice messages only live in memory.
Future<({Uint8List bytes, String? mime})?> readVoiceFile(String path) async {
  final file = File(path);
  if (!await file.exists()) return null;
  final bytes = await file.readAsBytes();
  try {
    await file.delete();
  } on FileSystemException {
    // Best effort: the OS cleans the temporary directory anyway.
  }
  return (bytes: bytes, mime: null);
}
