/// Dismessage WebSocket relay server.
library;

import 'dart:async';
import 'dart:io';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';

import 'src/gzip_middleware.dart';
import 'src/id_signer.dart';
import 'src/id_store.dart';
import 'src/relay.dart';

export 'src/id_signer.dart';
export 'src/id_store.dart';
export 'src/rate_limit.dart';
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
  Duration pingInterval = const Duration(seconds: kHeartbeatSeconds),
  String? ipHeader,
}) {
  FutureOr<Response> ws(Request request) {
    final info =
        request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
    final origin = clientIp(
      request.headers,
      info?.remoteAddress.address,
      ipHeader: ipHeader,
    );
    return webSocketHandler(
      (channel, _) => relay.handle(channel, origin: origin),
      // A client that vanished without closing (network lost, frozen
      // page) stops answering pings: drop it so it shows offline.
      pingInterval: pingInterval,
    )(request);
  }

  final web = webRoot != null && Directory(webRoot).existsSync()
      ? const Pipeline()
            .addMiddleware(_revalidate)
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

/// The client IP, for the log and the per-IP limits.
///
/// [ipHeader] names a header the front proxy sets itself, overwriting what
/// the client sent (Render: `cf-connecting-ip`, from Cloudflare). Otherwise
/// the last `x-forwarded-for` entry, the one added by the proxy in front:
/// the earlier ones come from the client and can be forged. Without a proxy,
/// the socket address.
String? clientIp(
  Map<String, String> headers,
  String? socketAddress, {
  String? ipHeader,
}) {
  final trusted = ipHeader == null ? null : headers[ipHeader.toLowerCase()];
  if (trusted != null && trusted.trim().isNotEmpty) return trusted.trim();
  final forwarded = headers['x-forwarded-for']?.split(',').last.trim();
  if (forwarded != null && forwarded.isNotEmpty) return forwarded;
  return socketAddress;
}

/// The client files keep their names from one build to the next (e.g. the
/// icon font, trimmed to the icons in use). Without this header browsers
/// guess a cache lifetime and keep an old copy: new icons then show blank.
/// "no-cache" still caches, but asks first; unchanged files cost a 304.
Handler _revalidate(Handler inner) => (request) async {
  final response = await inner(request);
  return response.change(headers: {'cache-control': 'no-cache'});
};

/// Convenience to build a relay backed by the JSON ID file.
///
/// The ID key comes from [idKey] (`DISMESSAGE_ID_KEY`), else from an
/// `id_key` file next to the ID file.
Future<Relay> relayWithFileStore(
  String path, {
  void Function(String line)? log,
  String? idKey,
  bool acceptLegacyIds = false,
}) async {
  final file = File(path);
  final signer = await IdSigner.load(
    fromEnv: idKey,
    file: File('${file.parent.path}/id_key'),
  );
  return Relay(
    await IdStore.open(file),
    log: log,
    signer: signer,
    acceptLegacyIds: acceptLegacyIds,
  );
}
