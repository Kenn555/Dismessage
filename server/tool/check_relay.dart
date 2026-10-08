// Smoke test of a running relay, e.g. after a deployment:
//
//   cd server && dart run tool/check_relay.dart wss://dismessage.onrender.com/ws
//
// Two throwaway clients get an ID from the relay, open a conversation,
// exchange keys and a sealed message; a frame in clear must be refused.
// Prints each step and OK / ÉCHEC; exit code 1 on failure. The IDs it gets
// are released at the end.
import 'dart:async';
import 'dart:io';

import 'package:async/async.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _timeout = Duration(seconds: 90); // Render Free wakes up slowly.

class _Client {
  _Client(this.name, this.channel)
    : frames = StreamQueue(channel.stream.map(Frame.decode));

  final String name;
  final WebSocketChannel channel;
  final StreamQueue<Frame> frames;
  late String id;
  late String secret;

  void send(Frame frame) => channel.sink.add(frame.encode());

  /// The next frame that is not a presence update.
  Future<Frame> next() async {
    while (true) {
      final frame = await frames.next.timeout(_timeout);
      if (frame is! PresenceFrame) return frame;
    }
  }

  Future<T> expect<T extends Frame>(String step) async {
    final frame = await next();
    if (frame is! T) {
      throw StateError(
        '$name, $step : attendu ${T.toString()}, reçu ${frame.encode()}',
      );
    }
    return frame;
  }
}

Future<void> main(List<String> args) async {
  final uri = Uri.parse(
    args.isEmpty ? 'wss://dismessage.onrender.com/ws' : args.first,
  );
  final watch = Stopwatch()..start();
  void ok(String step) => stdout.writeln(
    'OK     $step (${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s)',
  );
  final clients = <_Client>[];
  try {
    Future<_Client> connect(String name) async {
      final channel = WebSocketChannel.connect(uri);
      await channel.ready.timeout(_timeout);
      return _Client(name, channel)..also(clients.add);
    }

    final a = await connect('A');
    final b = await connect('B');
    ok('connexion WebSocket à $uri');

    for (final c in [a, b]) {
      c.send(const IdRequestFrame());
      final assigned = await c.expect<IdAssignedFrame>('id_request');
      c
        ..id = assigned.id
        ..secret = assigned.secret;
      c.send(RegisterFrame(id: c.id, secret: c.secret));
      await c.expect<RegisteredFrame>('register');
    }
    ok(
      'IDs attribués et signés : ${DismessageId.format(a.id)}, '
      '${DismessageId.format(b.id)}',
    );

    a.send(ConnectRequestFrame(to: b.id));
    await b.expect<IncomingRequestFrame>('demande');
    b.send(ConnectAcceptFrame(from: a.id));
    final sid = (await a.expect<SessionStartedFrame>('session')).sid;
    await b.expect<SessionStartedFrame>('session');
    ok('conversation ouverte');

    final ea = E2eSession(sid);
    final eb = E2eSession(sid);
    a.send(await ea.offer());
    b.send(await eb.offer());
    await eb.accept(await b.expect<KeyOfferFrame>('clé de A'));
    await ea.accept(await a.expect<KeyOfferFrame>('clé de B'));
    final code = await ea.safetyCode();
    if (code != await eb.safetyCode()) {
      throw StateError('codes de sécurité différents : relais interposé ?');
    }
    ok('clés échangées, même code de sécurité ($code)');

    const text = 'Test du relais';
    a.send(
      await ea.seal(
        MessageCommitFrame(
          sid: sid,
          seq: 1,
          text: text,
          mid: EntryId.generate(),
        ),
      ),
    );
    final sealed = await b.expect<SealedFrame>('message chiffré');
    if (sealed.encode().contains(text)) throw StateError('texte lisible');
    final opened = await eb.open(sealed) as MessageCommitFrame;
    if (opened.text != text) throw StateError('message altéré');
    ok('message chiffré transmis et déchiffré');

    a.send(
      MessageCommitFrame(
        sid: sid,
        seq: 2,
        text: 'en clair',
        mid: EntryId.generate(),
      ),
    );
    final refused = await a.expect<ErrorFrame>('trame en clair');
    if (refused.code != 'unencrypted') {
      throw StateError('trame en clair : ${refused.encode()}');
    }
    ok('trame en clair refusée');

    for (final c in [a, b]) {
      c.send(ReleaseFrame(id: c.id, secret: c.secret));
    }
    stdout.writeln('\nOK : le relais fonctionne.');
  } on Object catch (e) {
    stdout.writeln('\nÉCHEC : $e');
    exitCode = 1;
  } finally {
    for (final c in clients) {
      await c.channel.sink.close();
    }
  }
}

extension<T> on T {
  void also(void Function(T) f) => f(this);
}
