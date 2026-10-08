import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An ID and the secret proving its ownership.
class Identity {
  const Identity({required this.id, required this.secret});
  final String id;
  final String secret;
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

/// Persists the identity given by each relay: it only changes on explicit
/// regeneration.
///
/// The relay picks the ID and signs its secret with its own key, so an
/// identity only works on the relay that gave it: one per relay (host and
/// port), kept when switching servers and back.
class IdentityService {
  IdentityService(this._store);

  /// The identity of older versions, which chose their own ID: tried on a
  /// relay that has given none yet (it may keep it and sign it), never
  /// overwritten.
  static const idKey = 'dismessage.id';
  static const secretKey = 'dismessage.secret';

  static String idKeyFor(Uri relay) => '$idKey@${_relayKey(relay)}';
  static String secretKeyFor(Uri relay) => '$secretKey@${_relayKey(relay)}';

  static String _relayKey(Uri relay) => '${relay.host}:${relay.port}';

  final KeyValueStore _store;

  /// The identity for [relay]; null when it has to give one (`id_request`).
  Identity? load(Uri relay) =>
      _read(idKeyFor(relay), secretKeyFor(relay)) ?? _read(idKey, secretKey);

  Identity? _read(String idKey, String secretKey) {
    final id = _store.getString(idKey);
    final secret = _store.getString(secretKey);
    if (id == null || secret == null || !DismessageId.isValid(id)) return null;
    return Identity(id: id, secret: secret);
  }

  /// Keeps the identity [relay] gave (new, or the same ID now signed).
  Future<void> save(Uri relay, Identity identity) async {
    await _store.setString(idKeyFor(relay), identity.id);
    await _store.setString(secretKeyFor(relay), identity.secret);
  }
}
