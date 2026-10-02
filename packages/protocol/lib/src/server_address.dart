/// Turns what a user types or pastes (e.g. a VS Code tunnel link) into the
/// relay WebSocket URL.
abstract final class ServerAddress {
  static const path = '/ws';

  /// Examples:
  /// - `https://abc-8080.euw.devtunnels.ms` → `wss://abc-8080.euw.devtunnels.ms/ws`
  /// - `http://192.168.1.10:8080` → `ws://192.168.1.10:8080/ws`
  /// - `example.com` → `wss://example.com/ws`
  /// - `localhost:8080` → `ws://localhost:8080/ws`
  ///
  /// Returns null when the input cannot be a server address.
  static Uri? parse(String input) {
    var text = input.trim();
    if (text.isEmpty || text.contains(RegExp(r'\s'))) return null;
    if (!text.contains('://')) {
      final host = text.split(RegExp(r'[:/]')).first;
      text = '${_isLocal(host) ? 'ws' : 'wss'}://$text';
    }
    final Uri uri;
    try {
      uri = Uri.parse(text);
    } on FormatException {
      return null;
    }
    final scheme = switch (uri.scheme) {
      'https' || 'wss' => 'wss',
      'http' || 'ws' => 'ws',
      _ => null,
    };
    if (scheme == null || uri.host.isEmpty) return null;
    return Uri(
      scheme: scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: path,
    );
  }

  /// WebSocket URL of a relay that also served the current web page.
  static Uri sameOrigin(Uri page) => Uri(
    scheme: page.scheme == 'https' ? 'wss' : 'ws',
    host: page.host,
    port: page.hasPort ? page.port : null,
    path: path,
  );

  static bool _isLocal(String host) =>
      host == 'localhost' ||
      RegExp(
        r'^(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)',
      ).hasMatch(host);
}
