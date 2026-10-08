// Test peer for manual checks on a device: a minimal Dismessage client
// driven over HTTP (port 9555).
//
//   cd server && dart run tool/test_peer.dart ws://localhost:8099/ws
//
//   curl localhost:9555/request?to=123456789   ask for a chat
//   curl localhost:9555/cancel                  withdraw the request
//   curl "localhost:9555/draft?text=Salut"      live draft
//   curl "localhost:9555/send?text=Salut"       send a message
//   curl localhost:9555/log                     frames received
import 'dart:io';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

Future<void> main(List<String> args) async {
  final uri = Uri.parse(args.isEmpty ? 'ws://localhost:8099/ws' : args.first);
  final channel = WebSocketChannel.connect(uri);
  await channel.ready;
  // The relay picks the ID (id_request), then the peer registers it.
  var id = '';
  final log = <String>[];
  String? sid;
  String? asked;
  var seq = 0;
  void send(Frame frame) => channel.sink.add(frame.encode());

  channel.stream.listen((raw) {
    final frame = Frame.decode(raw);
    log.add(frame.encode());
    switch (frame) {
      case IdAssignedFrame(id: final assigned, :final secret):
        id = assigned;
        send(RegisterFrame(id: assigned, secret: secret));
        stdout.writeln('peer $assigned on $uri');
      case IncomingRequestFrame(:final from):
        send(ConnectAcceptFrame(from: from));
      case SessionStartedFrame(sid: final started):
        sid = started;
        seq = 0;
      default:
        break;
    }
  });
  send(const IdRequestFrame());

  final server = await HttpServer.bind('127.0.0.1', 9555);
  await for (final req in server) {
    final q = req.uri.queryParameters;
    var out = 'ok';
    switch (req.uri.path) {
      case '/id':
        out = id;
      case '/request':
        asked = q['to'];
        send(ConnectRequestFrame(to: asked!));
      case '/cancel':
        final peer = asked;
        if (peer != null) send(ConnectCancelFrame(peer: peer));
      case '/draft':
        if (sid == null) {
          out = 'no session';
        } else {
          send(DraftSnapshotFrame(sid: sid!, seq: ++seq, text: q['text']!));
        }
      case '/send':
        if (sid == null) {
          out = 'no session';
        } else {
          send(
            MessageCommitFrame(
              sid: sid!,
              seq: ++seq,
              text: q['text']!,
              mid: EntryId.generate(),
            ),
          );
        }
      case '/log':
        out = log.join('\n');
      default:
        out = 'unknown';
    }
    req.response.write(out);
    await req.response.close();
  }
}
