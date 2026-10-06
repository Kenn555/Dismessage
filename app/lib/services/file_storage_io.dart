import 'dart:async';
import 'dart:io';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'file_storage.dart';

FileStorage createFileStorage() =>
    Platform.isAndroid ? AndroidFileStorage() : DesktopFileStorage();

Future<ChosenFile?> pickFile() async {
  if (Platform.isAndroid) return AndroidFileStorage.pick();
  // Windows: file_selector_windows, through its interface (the app-facing
  // package would pull the Android implementation into the Gradle build).
  final XFile? file;
  try {
    file = await FileSelectorPlatform.instance.openFile();
  } on PlatformException catch (e) {
    throw FileStorageException(e.message ?? e.code);
  }
  if (file == null) return null;
  final local = File(file.path);
  return IoChosenFile(local, file.name, await local.length());
}

/// A file on disk, read with one handle kept open between chunks.
class IoChosenFile implements ChosenFile {
  IoChosenFile(this._file, this.name, this.size);

  final File _file;
  @override
  final String name;
  @override
  final int size;
  RandomAccessFile? _handle;

  @override
  Future<Uint8List> read(int offset, int length) async {
    final handle = _handle ??= await _file.open();
    await handle.setPosition(offset);
    return handle.read(length);
  }

  @override
  Future<void> close() async {
    final handle = _handle;
    _handle = null;
    await handle?.close();
  }
}

/// Windows (and other desktops): straight into the Downloads folder. The
/// file is written as `name.part`, renamed once complete.
class DesktopFileStorage implements FileStorage {
  DesktopFileStorage({Future<Directory?> Function()? directory})
    : _directory = directory ?? getDownloadsDirectory;

  final Future<Directory?> Function() _directory;

  static const partSuffix = '.part';

  @override
  Future<FileSink> create(String name, int size) async {
    final Directory? dir;
    try {
      dir = await _directory();
    } catch (_) {
      throw const FileStorageException('Dossier Téléchargements introuvable.');
    }
    if (dir == null) {
      throw const FileStorageException('Dossier Téléchargements introuvable.');
    }
    try {
      await dir.create(recursive: true);
      final target = _unique(dir, name);
      final part = File(_join(dir, '$target$partSuffix'));
      final handle = await part.open(mode: FileMode.writeOnly);
      return _DesktopSink(dir, target, part, handle);
    } on FileSystemException catch (e) {
      throw FileStorageException(_describe(e));
    }
  }

  static String _unique(Directory dir, String name) => FileNames.unique(
    name,
    (candidate) =>
        File(_join(dir, candidate)).existsSync() ||
        File(_join(dir, '$candidate$partSuffix')).existsSync(),
  );

  static String _join(Directory dir, String name) =>
      '${dir.path}${Platform.pathSeparator}$name';

  static String _describe(FileSystemException e) {
    final reason = e.osError?.message ?? e.message;
    return "Impossible d'écrire le fichier ($reason).";
  }
}

class _DesktopSink implements FileSink {
  _DesktopSink(this._dir, this.name, this._part, this._handle);

  final Directory _dir;
  final File _part;
  final RandomAccessFile _handle;
  bool _closed = false;

  @override
  String name;

  @override
  Future<void> write(Uint8List bytes) async {
    try {
      await _handle.writeFrom(bytes);
    } on FileSystemException catch (e) {
      throw FileStorageException(DesktopFileStorage._describe(e));
    }
  }

  @override
  Future<SavedFile> close() async {
    try {
      _closed = true;
      await _handle.close();
      // Another file may have taken the name meanwhile.
      if (File(DesktopFileStorage._join(_dir, name)).existsSync()) {
        name = DesktopFileStorage._unique(_dir, name);
      }
      final saved = await _part.rename(DesktopFileStorage._join(_dir, name));
      return DesktopSavedFile(saved.path, name);
    } on FileSystemException catch (e) {
      throw FileStorageException(DesktopFileStorage._describe(e));
    }
  }

  @override
  Future<void> abort() async {
    try {
      if (!_closed) {
        _closed = true;
        await _handle.close();
      }
      if (await _part.exists()) await _part.delete();
    } on FileSystemException {
      // Best effort: a leftover .part file is harmless.
    }
  }
}

class DesktopSavedFile implements SavedFile {
  DesktopSavedFile(this.path, this.name);

  final String path;
  @override
  final String name;

  @override
  String get location => 'Téléchargements';

  @override
  bool get canOpen =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  bool get canShowInFolder => Platform.isWindows || Platform.isMacOS;

  @override
  Future<bool> open() async {
    if (!File(path).existsSync()) return false;
    return _run(switch (Platform.operatingSystem) {
      'windows' => ('explorer.exe', [path]),
      'macos' => ('open', [path]),
      _ => ('xdg-open', [path]),
    });
  }

  @override
  Future<bool> showInFolder() async {
    if (!File(path).existsSync()) return false;
    return _run(switch (Platform.operatingSystem) {
      'windows' => ('explorer.exe', ['/select,', path]),
      _ => ('open', ['-R', path]),
    });
  }

  static Future<bool> _run((String, List<String>) command) async {
    try {
      await Process.start(
        command.$1,
        command.$2,
        mode: ProcessStartMode.detached,
      );
      return true;
    } on ProcessException {
      return false;
    }
  }
}

/// Android: our own channel (`FileHandler.kt`). The system picker, then
/// MediaStore Downloads/Dismessage, written while the file arrives.
class AndroidFileStorage implements FileStorage {
  static const channel = MethodChannel('dismessage/files');

  static Future<ChosenFile?> pick() async {
    final Map<Object?, Object?>? picked;
    try {
      picked = await channel.invokeMapMethod<Object?, Object?>('pick');
    } on PlatformException catch (e) {
      throw FileStorageException(e.message ?? e.code);
    }
    if (picked == null) return null;
    return _AndroidChosenFile(
      picked['handle']! as int,
      picked['name']! as String,
      picked['size']! as int,
    );
  }

  @override
  Future<FileSink> create(String name, int size) async {
    try {
      final created = await channel.invokeMapMethod<Object?, Object?>(
        'create',
        {'name': name},
      );
      return _AndroidSink(
        created!['handle']! as int,
        created['name']! as String,
      );
    } on PlatformException catch (e) {
      throw FileStorageException(
        "Impossible d'enregistrer le fichier (${e.message ?? e.code}).",
      );
    }
  }
}

class _AndroidChosenFile implements ChosenFile {
  _AndroidChosenFile(this._handle, this.name, this.size);

  final int _handle;
  @override
  final String name;
  @override
  final int size;

  @override
  Future<Uint8List> read(int offset, int length) async {
    try {
      final bytes = await AndroidFileStorage.channel.invokeMethod<Uint8List>(
        'read',
        {'handle': _handle, 'offset': offset, 'length': length},
      );
      return bytes ?? Uint8List(0);
    } on PlatformException catch (e) {
      throw FileStorageException(
        'Lecture du fichier impossible (${e.message ?? e.code}).',
      );
    }
  }

  @override
  Future<void> close() async {
    try {
      await AndroidFileStorage.channel.invokeMethod<void>('closeRead', {
        'handle': _handle,
      });
    } on PlatformException {
      // Already closed.
    }
  }
}

class _AndroidSink implements FileSink {
  _AndroidSink(this._handle, this.name);

  final int _handle;
  @override
  String name;

  @override
  Future<void> write(Uint8List bytes) async {
    try {
      await AndroidFileStorage.channel.invokeMethod<void>('write', {
        'handle': _handle,
        'bytes': bytes,
      });
    } on PlatformException catch (e) {
      throw FileStorageException(
        "Impossible d'écrire le fichier (${e.message ?? e.code}).",
      );
    }
  }

  @override
  Future<SavedFile> close() async {
    try {
      final saved = await AndroidFileStorage.channel
          .invokeMapMethod<Object?, Object?>('finish', {'handle': _handle});
      name = saved!['name']! as String;
      return _AndroidSavedFile(
        saved['uri'] as String?,
        name,
        saved['location']! as String,
      );
    } on PlatformException catch (e) {
      throw FileStorageException(
        "Impossible d'enregistrer le fichier (${e.message ?? e.code}).",
      );
    }
  }

  @override
  Future<void> abort() async {
    try {
      await AndroidFileStorage.channel.invokeMethod<void>('abort', {
        'handle': _handle,
      });
    } on PlatformException {
      // Best effort.
    }
  }
}

class _AndroidSavedFile implements SavedFile {
  _AndroidSavedFile(this._uri, this.name, this.location);

  /// content:// URI (MediaStore), null when it cannot be shared with
  /// another app (Android 9 and older: app folder).
  final String? _uri;
  @override
  final String name;
  @override
  final String location;

  @override
  bool get canOpen => _uri != null;

  @override
  bool get canShowInFolder => _uri != null;

  @override
  Future<bool> open() => _call('open', {'uri': _uri});

  @override
  Future<bool> showInFolder() => _call('showDownloads', null);

  static Future<bool> _call(String method, Object? arguments) async {
    try {
      return await AndroidFileStorage.channel.invokeMethod<bool>(
            method,
            arguments,
          ) ??
          false;
    } on PlatformException {
      return false;
    }
  }
}
