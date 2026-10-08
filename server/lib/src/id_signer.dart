import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Signs IDs: the secret of an ID is `HMAC-SHA256(key, id)`.
///
/// The relay can then check a secret without remembering anything, so an ID
/// survives a restart that loses the store (Render Free has no disk). Only
/// the relay picks IDs (`id_request`): nobody can get the secret of an ID
/// someone else owns. The key never leaves the server and is never logged.
class IdSigner {
  IdSigner(List<int> key) : _hmac = Hmac(sha256, key) {
    if (key.length < minKeyBytes) {
      throw ArgumentError('ID key too short (${key.length} bytes)');
    }
  }

  /// A random key, lost when the process ends (tests).
  factory IdSigner.random([Random? random]) {
    final rng = random ?? Random.secure();
    return IdSigner(List.generate(32, (_) => rng.nextInt(256)));
  }

  /// The key from [fromEnv] (the `DISMESSAGE_ID_KEY` variable, any text of
  /// [minKeyBytes] bytes or more), else from [file], created on first use.
  ///
  /// A file key only lasts as long as the disk: on a host without one, every
  /// restart would change all secrets, hence [usesFile] for a warning.
  static Future<IdSigner> load({String? fromEnv, required File file}) async {
    if (fromEnv != null && fromEnv.isNotEmpty) {
      return IdSigner(utf8.encode(fromEnv)).._fromFile = false;
    }
    if (!await file.exists()) {
      final rng = Random.secure();
      final key = base64Url.encode(List.generate(32, (_) => rng.nextInt(256)));
      await file.parent.create(recursive: true);
      await file.writeAsString(key);
    }
    final key = (await file.readAsString()).trim();
    return IdSigner(utf8.encode(key)).._fromFile = true;
  }

  static const int minKeyBytes = 32;

  final Hmac _hmac;
  bool _fromFile = false;

  /// Whether the key came from a file rather than the environment.
  bool get usesFile => _fromFile;

  String sign(String id) =>
      base64Url.encode(_hmac.convert(utf8.encode('dismessage-id:$id')).bytes);

  /// Constant-time comparison: timing does not leak how much matched.
  bool verify(String id, String secret) {
    final expected = sign(id);
    if (expected.length != secret.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected.codeUnitAt(i) ^ secret.codeUnitAt(i);
    }
    return diff == 0;
  }
}
