import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'file_storage.dart';

FileStorage createFileStorage() => BrowserFileStorage();

/// The browser's file chooser. Completes with null when cancelled (where
/// the browser reports it).
Future<ChosenFile?> pickFile() {
  final completer = Completer<ChosenFile?>();
  final input = web.HTMLInputElement()..type = 'file';
  input.onchange = (web.Event _) {
    final file = input.files?.item(0);
    if (!completer.isCompleted) {
      completer.complete(file == null ? null : _BrowserChosenFile(file));
    }
  }.toJS;
  input.addEventListener(
    'cancel',
    (web.Event _) {
      if (!completer.isCompleted) completer.complete(null);
    }.toJS,
  );
  input.click();
  return completer.future;
}

/// Reads slices of the file: it is never loaded whole.
class _BrowserChosenFile implements ChosenFile {
  _BrowserChosenFile(this._file);

  final web.File _file;

  @override
  String get name => _file.name;

  @override
  int get size => _file.size;

  @override
  Future<Uint8List> read(int offset, int length) async {
    final slice = _file.slice(offset, offset + length);
    final buffer = await slice.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  }

  @override
  Future<void> close() async {}
}

/// A page cannot write to the disk: the chunks stay in memory, then the
/// browser downloads the file as usual (its Downloads folder).
class BrowserFileStorage implements FileStorage {
  @override
  Future<FileSink> create(String name, int size) async => _BrowserSink(name);
}

class _BrowserSink implements FileSink {
  _BrowserSink(this.name);

  @override
  final String name;
  final List<JSUint8Array> _parts = [];

  @override
  Future<void> write(Uint8List bytes) async => _parts.add(bytes.toJS);

  @override
  Future<SavedFile> close() async {
    final blob = web.Blob(_parts.toJS);
    _parts.clear();
    final url = web.URL.createObjectURL(blob);
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = name
      ..style.display = 'none';
    web.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
    // Revoking at once can cancel the download in some browsers.
    Timer(const Duration(minutes: 1), () => web.URL.revokeObjectURL(url));
    return _BrowserSavedFile(name);
  }

  @override
  Future<void> abort() async => _parts.clear();
}

class _BrowserSavedFile implements SavedFile {
  _BrowserSavedFile(this.name);

  @override
  final String name;

  @override
  String get location => 'Téléchargements du navigateur';

  @override
  bool get canOpen => false;

  @override
  bool get canShowInFolder => false;

  @override
  Future<bool> open() async => false;

  @override
  Future<bool> showInFolder() async => false;
}
