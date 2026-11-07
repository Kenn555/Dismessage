import 'dart:io';

import 'package:flutter/services.dart';

import 'attachments.dart';
import 'clipboard_images.dart';
import 'file_storage.dart';
import 'file_storage_io.dart';

ClipboardImages platformClipboardImages() => Platform.isWindows
    ? const _WindowsClipboardImages()
    : const NoClipboardImages();

/// The runner reads the clipboard (`windows/runner/clipboard.cpp`): a copied
/// picture (PNG, or a bitmap turned into BMP), or copied files.
class _WindowsClipboardImages implements ClipboardImages {
  const _WindowsClipboardImages();

  static const _channel = MethodChannel('dismessage/clipboard');

  @override
  bool get readsOnPasteKey => true;

  @override
  Future<Attachments> read() async {
    try {
      final content = await _channel.invokeMapMethod<Object?, Object?>('read');
      if (content == null) return const Attachments();
      final files = <ChosenFile>[];
      for (final path in (content['files']! as List).cast<String>()) {
        final file = File(path);
        // A copied folder is not a file to send.
        if (!await file.exists()) continue;
        final name = path.split(RegExp(r'[/\\]')).last;
        files.add(IoChosenFile(file, name, await file.length()));
      }
      return Attachments(
        images: (content['images']! as List).cast<Uint8List>(),
        files: files,
      );
    } on PlatformException {
      return const Attachments();
    } on MissingPluginException {
      return const Attachments();
    } on FileSystemException {
      return const Attachments();
    }
  }

  @override
  Stream<Attachments> get pasted => const Stream.empty();
}
