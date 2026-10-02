import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Persistent mapping `ID → sha256(secret)`. Secrets are never stored.
class IdStore {
  IdStore._(this._file, this._hashes);

  /// In-memory store (tests).
  IdStore.memory() : this._(null, {});

  /// Store backed by a JSON file, created on first write.
  static Future<IdStore> open(File file) async {
    final hashes = <String, String>{};
    if (await file.exists()) {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      json.forEach((id, hash) => hashes[id] = hash as String);
    }
    return IdStore._(file, hashes);
  }

  final File? _file;
  final Map<String, String> _hashes;

  bool contains(String id) => _hashes.containsKey(id);

  /// Claims [id] for [secret]. True if the ID was free or already owned.
  Future<bool> claim(String id, String secret) async {
    final hash = _hash(secret);
    final existing = _hashes[id];
    if (existing != null) return existing == hash;
    _hashes[id] = hash;
    await _save();
    return true;
  }

  /// Frees [id] if [secret] proves ownership.
  Future<bool> release(String id, String secret) async {
    if (_hashes[id] != _hash(secret)) return false;
    _hashes.remove(id);
    await _save();
    return true;
  }

  static String _hash(String secret) =>
      sha256.convert(utf8.encode(secret)).toString();

  Future<void> _save() async {
    final file = _file;
    if (file == null) return;
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(_hashes));
    await tmp.rename(file.path);
  }
}
