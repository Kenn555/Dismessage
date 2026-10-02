import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/foundation.dart';

import 'services/identity_service.dart';

/// Production relay (Render).
const kProductionServer = 'https://dismessage.onrender.com';

/// Default relay URL, overridable with
/// `--dart-define=SERVER_URL=https://example.com`.
Uri defaultServerUri() => chooseServerUri(
  override: const String.fromEnvironment('SERVER_URL'),
  isWeb: kIsWeb,
  isRelease: kReleaseMode,
  isAndroid: defaultTargetPlatform == TargetPlatform.android,
  page: kIsWeb ? Uri.base : null,
);

/// Pure decision logic behind [defaultServerUri], kept testable.
@visibleForTesting
Uri chooseServerUri({
  required String override,
  required bool isWeb,
  required bool isRelease,
  required bool isAndroid,
  Uri? page,
}) {
  final parsed = ServerAddress.parse(override);
  if (parsed != null) return parsed;
  final production = ServerAddress.parse(kProductionServer)!;
  if (isWeb) {
    // GitHub Pages only hosts files: talk to the production relay.
    // Anywhere else, the page was served by a relay: talk back to it.
    final host = page?.host ?? '';
    return host.endsWith('.github.io')
        ? production
        : ServerAddress.sameOrigin(page!);
  }
  if (isRelease) return production;
  // Debug: a relay started locally (start-server.bat). The Android
  // emulator reaches the host machine through 10.0.2.2.
  return Uri.parse(
    isAndroid ? 'ws://10.0.2.2:8080/ws' : 'ws://localhost:8080/ws',
  );
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
