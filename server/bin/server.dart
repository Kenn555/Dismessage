import 'dart:io';

import 'package:dismessage_server/dismessage_server.dart';

Future<void> main() async {
  final env = Platform.environment;
  final port = int.tryParse(env['PORT'] ?? '') ?? 8080;
  final dataFile = env['DISMESSAGE_IDS'] ?? 'data/ids.json';
  final webRoot = env['DISMESSAGE_WEB'] ?? '../app/build/web';
  final relay = await relayWithFileStore(dataFile, log: _log);
  final server = await serve(relay, port: port, webRoot: webRoot);
  stdout.writeln('Dismessage relay: ws://localhost:${server.port}/ws');
  if (Directory(webRoot).existsSync()) {
    stdout.writeln('Client web     : http://localhost:${server.port}/');
  } else {
    stdout.writeln(
      'Client web absent ($webRoot) : lancer `flutter build web` dans app/',
    );
  }
}

/// Timestamped activity log (never contains secrets).
void _log(String line) {
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  stdout.writeln(
    '[${two(now.hour)}:${two(now.minute)}:${two(now.second)}] $line',
  );
}
