import 'dart:io';

import 'package:shelf/shelf.dart';

const _compressible = [
  'text/',
  'application/javascript',
  'application/json',
  'application/wasm',
  'image/svg+xml',
];

/// Gzips static responses when the client accepts it.
///
/// Slow links (e.g. a VS Code tunnel) make the 2+ MB web client take minutes
/// to load; gzip divides that by ~3. Compressed bodies are cached per path
/// and Last-Modified, so each file is compressed once.
Middleware gzipMiddleware() {
  final cache = <String, List<int>>{};
  return (inner) => (request) async {
    final response = await inner(request);
    final accepts =
        request.headers['accept-encoding']?.contains('gzip') ?? false;
    final type = response.headers['content-type'] ?? '';
    if (!accepts ||
        response.statusCode != 200 ||
        response.headers.containsKey('content-encoding') ||
        !_compressible.any(type.startsWith)) {
      return response;
    }
    final key = '${request.url.path}|${response.headers['last-modified']}';
    final body = cache[key] ??= gzip.encode(
      await response.read().expand((chunk) => chunk).toList(),
    );
    return response.change(
      body: body,
      headers: {
        'content-encoding': 'gzip',
        'content-length': '${body.length}',
        'vary': 'Accept-Encoding',
      },
    );
  };
}
