/// Dismessage WebSocket relay server.
library;

import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';

import 'src/gzip_middleware.dart';
import 'src/id_store.dart';
import 'src/relay.dart';

export 'src/id_store.dart';
export 'src/relay.dart';

/// Starts the relay on [port] (0 = ephemeral). WebSocket endpoint: `/ws`.
///
/// If [webRoot] points to a Flutter web build, the client is served too, so
/// a single public link (e.g. a VS Code tunnel) gives both page and relay.
Future<HttpServer> serve(
  Relay relay, {
  Object address = '0.0.0.0',
  int port = 8080,
  String? webRoot,
}) {
  FutureOr<Response> ws(Request request) {
    // Behind a tunnel or proxy, the real client IP is forwarded.
    final info =
        request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
    final origin =
        request.headers['x-forwarded-for']?.split(',').first.trim() ??
        info?.remoteAddress.address;
    return webSocketHandler(
      (channel, _) => relay.handle(channel, origin: origin),
    )(request);
  }

  final web = webRoot != null && Directory(webRoot).existsSync()
      ? const Pipeline()
            .addMiddleware(gzipMiddleware())
            .addHandler(
              createStaticHandler(webRoot, defaultDocument: 'index.html'),
            )
      : null;
  FutureOr<Response> handler(Request request) => switch (request.url.path) {
    'ws' => ws(request),
    'health' => Response.ok('ok'),
    _ when web != null => web(request),
    _ => Response.notFound('not found'),
  };
  return shelf_io.serve(handler, address, port);
}

/// Convenience to build a relay backed by the JSON ID file.
Future<Relay> relayWithFileStore(
  String path, {
  void Function(String line)? log,
}) async => Relay(await IdStore.open(File(path)), log: log);
