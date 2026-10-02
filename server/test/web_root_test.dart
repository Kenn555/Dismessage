import 'dart:io';

import 'package:dismessage_server/dismessage_server.dart';
import 'package:test/test.dart';

Future<(int, String)> get(int port, String path) async {
  final client = HttpClient();
  try {
    final request = await client.get('localhost', port, path);
    final response = await request.close();
    final body = await response
        .transform(const SystemEncoding().decoder)
        .join();
    return (response.statusCode, body);
  } finally {
    client.close(force: true);
  }
}

void main() {
  late Directory web;
  final servers = <HttpServer>[];

  setUp(() async {
    web = await Directory.systemTemp.createTemp('dismessage_web');
    await File('${web.path}/index.html').writeAsString('<p>Dismessage</p>');
    await File('${web.path}/main.dart.js').writeAsString('// js');
  });

  tearDown(() async {
    for (final s in servers) {
      await s.close(force: true);
    }
    servers.clear();
    await web.delete(recursive: true);
  });

  Future<int> start(String? webRoot) async {
    final server = await serve(
      Relay(IdStore.memory()),
      address: 'localhost',
      port: 0,
      webRoot: webRoot,
    );
    servers.add(server);
    return server.port;
  }

  test('serves the web client next to the relay', () async {
    final port = await start(web.path);
    expect(await get(port, '/'), (200, '<p>Dismessage</p>'));
    expect((await get(port, '/main.dart.js')).$1, 200);
    expect(await get(port, '/health'), (200, 'ok'));
  });

  test('without a web build, only the relay answers', () async {
    final port = await start('${web.path}/missing');
    expect((await get(port, '/')).$1, 404);
    expect(await get(port, '/health'), (200, 'ok'));
  });

  test('static files are gzipped when the client accepts it', () async {
    final big = 'console.log("Dismessage");\n' * 2000;
    await File('${web.path}/main.dart.js').writeAsString(big);
    final port = await start(web.path);

    final client = HttpClient()..autoUncompress = false;
    try {
      for (var i = 0; i < 2; i++) {
        // Twice: the second answer comes from the compression cache.
        final request = await client.get('localhost', port, '/main.dart.js');
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip, br');
        final response = await request.close();
        final bytes = await response.expand((c) => c).toList();
        expect(response.headers.value('content-encoding'), 'gzip');
        expect(bytes.length, lessThan(big.length ~/ 10));
        expect(String.fromCharCodes(gzip.decode(bytes)), big);
      }

      final plain = await client.get('localhost', port, '/main.dart.js');
      plain.headers.removeAll(HttpHeaders.acceptEncodingHeader);
      final response = await plain.close();
      final bytes = await response.expand((c) => c).toList();
      expect(response.headers.value('content-encoding'), isNull);
      expect(bytes.length, big.length);
    } finally {
      client.close(force: true);
    }
  });
}
