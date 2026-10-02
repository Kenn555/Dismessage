import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An ID and the secret proving its ownership.
class Identity {
  const Identity({required this.id, required this.secret});
  final String id;
  final String secret;

  factory Identity.generate() => Identity(
    id: DismessageId.generate(),
    secret: DismessageId.generateSecret(),
  );
}

/// Minimal persistent storage used by [IdentityService].
abstract interface class KeyValueStore {
  String? getString(String key);
  Future<void> setString(String key, String value);
}

class PrefsStore implements KeyValueStore {
  PrefsStore(this._prefs);
  final SharedPreferences _prefs;

  @override
  String? getString(String key) => _prefs.getString(key);

  @override
  Future<void> setString(String key, String value) =>
      _prefs.setString(key, value);
}

class MemoryStore implements KeyValueStore {
  final Map<String, String> values = {};

  @override
  String? getString(String key) => values[key];

  @override
  Future<void> setString(String key, String value) async => values[key] = value;
}

/// Persists the local identity: it only changes on explicit regeneration.
class IdentityService {
  IdentityService(this._store);

  static const idKey = 'dismessage.id';
  static const secretKey = 'dismessage.secret';

  final KeyValueStore _store;

  /// Returns the stored identity, creating one on first launch.
  Future<Identity> load() async {
    final id = _store.getString(idKey);
    final secret = _store.getString(secretKey);
    if (id != null && secret != null && DismessageId.isValid(id)) {
      return Identity(id: id, secret: secret);
    }
    return regenerate();
  }

  /// Replaces the stored identity with a brand new one.
  Future<Identity> regenerate() async {
    final identity = Identity.generate();
    await _store.setString(idKey, identity.id);
    await _store.setString(secretKey, identity.secret);
    return identity;
  }
}
