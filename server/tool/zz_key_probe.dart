import 'dart:io';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

Future<void> main(List<String> args) async {
  final channel = WebSocketChannel.connect(Uri.parse('wss://dismessage.onrender.com/ws'));
  await channel.ready;
  final frames = channel.stream.map(Frame.decode).where((f) => f is! PresenceFrame).asBroadcastStream();
  if (args.first == 'get') {
    channel.sink.add(const IdRequestFrame().encode());
    final a = await frames.first as IdAssignedFrame;
    File(args[1]).writeAsStringSync('${a.id}\n${a.secret}');
    stdout.writeln('ID obtenu : ${a.id}');
  } else {
    final [id, secret] = File(args[1]).readAsLinesSync();
    channel.sink.add(RegisterFrame(id: id, secret: secret).encode());
    stdout.writeln('réponse : ${(await frames.first).encode()}');
    channel.sink.add(ReleaseFrame(id: id, secret: secret).encode());
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  await channel.sink.close();
}
