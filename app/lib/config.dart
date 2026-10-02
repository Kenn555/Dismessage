import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';

import 'services/identity_service.dart';

/// Default relay URL, overridable with
/// `--dart-define=SERVER_URL=https://abc-8080.euw.devtunnels.ms`.
Uri defaultServerUri() {
  const fromEnv = String.fromEnvironment('SERVER_URL');
  final parsed = ServerAddress.parse(fromEnv);
  if (parsed != null) return parsed;
  // The web client is served by the relay itself: talk back to it.
  if (kIsWeb) return ServerAddress.sameOrigin(Uri.base);
  // The Android emulator reaches the host machine through 10.0.2.2.
  if (defaultTargetPlatform == TargetPlatform.android) {
    return Uri.parse('ws://10.0.2.2:8080/ws');
  }
  return Uri.parse('ws://localhost:8080/ws');
}

/// Server address chosen by the user, persisted across launches.
class ServerSettings {
  ServerSettings(this._store, {Uri? fallback})
    : _fallback = fallback ?? defaultServerUri();

  static const key = 'dismessage.server';

  final KeyValueStore _store;
  final Uri _fallback;

  Uri get serverUri =>
      ServerAddress.parse(_store.getString(key) ?? '') ?? _fallback;

  bool get isCustom => _store.getString(key) != null;

  Future<void> save(Uri uri) => _store.setString(key, uri.toString());
}
