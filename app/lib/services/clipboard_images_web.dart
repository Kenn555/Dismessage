import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:web/web.dart' as web;

import 'attachments.dart';
import 'clipboard_images.dart';
import 'file_storage.dart';
import 'file_storage_web.dart';

ClipboardImages platformClipboardImages() => _BrowserClipboardImages.instance;

/// The browser's `paste` event: the text field gets the text, pictures and
/// files come here.
class _BrowserClipboardImages implements ClipboardImages {
  _BrowserClipboardImages._() {
    web.document.addEventListener('paste', _onPaste.toJS, true.toJS);
  }

  static final instance = _BrowserClipboardImages._();

  final _pasted = StreamController<Attachments>.broadcast();

  @override
  bool get readsOnPasteKey => false;

  @override
  Future<Attachments> read() async => const Attachments();

  @override
  Stream<Attachments> get pasted => _pasted.stream;

  void _onPaste(web.ClipboardEvent event) {
    final list = event.clipboardData?.files;
    if (list == null) return;
    final images = <web.File>[];
    final others = <ChosenFile>[];
    for (var i = 0; i < list.length; i++) {
      final file = list.item(i);
      if (file == null) continue;
      if (file.type.startsWith('image/')) {
        images.add(file);
      } else {
        others.add(BrowserChosenFile(file));
      }
    }
    if (images.isEmpty && others.isEmpty) return;
    event.preventDefault();
    unawaited(_read(images, others));
  }

  Future<void> _read(List<web.File> pictures, List<ChosenFile> others) async {
    final images = <Uint8List>[];
    final files = [...others];
    for (final file in pictures) {
      if (images.length >= kMaxImagesPerSend) {
        files.add(BrowserChosenFile(file));
        continue;
      }
      try {
        images.add(await _shrink(file));
      } catch (_) {
        // Unreadable as a picture: it still goes, as a file.
        files.add(BrowserChosenFile(file));
      }
    }
    if (images.isNotEmpty || files.isNotEmpty) {
      _pasted.add(Attachments(images: images, files: files));
    }
  }

  /// Downscaled by the browser's canvas: the Dart encoder runs on the UI
  /// thread here, and a large screenshot would freeze the page.
  static Future<Uint8List> _shrink(web.File file) async {
    final bitmap = await web.window.createImageBitmap(file).toDart;
    final longest = math.max(bitmap.width, bitmap.height);
    if (longest <= kMaxImageSide && file.size <= kMaxImageBytes) {
      bitmap.close();
      return (await file.arrayBuffer().toDart).toDart.asUint8List();
    }
    final scale = math.min(1.0, kMaxImageSide / longest);
    final width = (bitmap.width * scale).round();
    final height = (bitmap.height * scale).round();
    final canvas = web.HTMLCanvasElement()
      ..width = width
      ..height = height;
    final context = canvas.getContext('2d')! as web.CanvasRenderingContext2D;
    // JPEG has no transparency: white behind, as ImageCodec does.
    context
      ..fillStyle = 'white'.toJS
      ..fillRect(0, 0, width, height)
      ..drawImage(bitmap, 0, 0, width, height);
    bitmap.close();
    final blob = Completer<web.Blob?>();
    canvas.toBlob(
      ((web.Blob? result) => blob.complete(result)).toJS,
      'image/jpeg',
      0.92.toJS,
    );
    final result = await blob.future;
    if (result == null) throw StateError('canvas');
    return (await result.arrayBuffer().toDart).toDart.asUint8List();
  }
}
