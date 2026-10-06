import 'dart:typed_data';

import 'file_storage_io.dart'
    if (dart.library.js_interop) 'file_storage_web.dart'
    as platform;

class FileStorageException implements Exception {
  const FileStorageException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A file chosen by the user, read chunk by chunk (never whole in memory,
/// except where the platform gives no choice).
abstract class ChosenFile {
  String get name;
  int get size;

  /// Reads [length] bytes from [offset]. Chunks are read in order.
  Future<Uint8List> read(int offset, int length);

  Future<void> close();
}

/// A received file being written where the user keeps downloads.
abstract class FileSink {
  /// Name on disk (may differ from the sender's to avoid a clash).
  String get name;

  Future<void> write(Uint8List bytes);

  /// Finishes the file: only then does it appear under its real name.
  Future<SavedFile> close();

  /// Stops and deletes what was written.
  Future<void> abort();
}

/// A received file, saved.
abstract class SavedFile {
  String get name;

  /// Where it is, for the user ("Téléchargements").
  String get location;

  bool get canOpen;
  bool get canShowInFolder;

  /// Opens it with the default application. False if impossible.
  Future<bool> open();

  /// Shows it in its folder. False if impossible.
  Future<bool> showInFolder();
}

/// Where received files go: the downloads of this device.
abstract class FileStorage {
  /// Starts writing a file of [size] bytes named [name] (already
  /// sanitized). Throws [FileStorageException].
  Future<FileSink> create(String name, int size);
}

/// Lets the user choose a file to send; null if cancelled.
typedef FilePickerFn = Future<ChosenFile?> Function();

/// The downloads of this platform.
FileStorage platformFileStorage() => platform.createFileStorage();

/// The file chooser of this platform. Throws [FileStorageException].
Future<ChosenFile?> platformPickFile() => platform.pickFile();
