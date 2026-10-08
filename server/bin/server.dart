import 'dart:io';

import 'package:dismessage_server/dismessage_server.dart';

Future<void> main() async {
  final env = Platform.environment;
  final port = int.tryParse(env['PORT'] ?? '') ?? 8080;
  final dataFile = env['DISMESSAGE_IDS'] ?? 'data/ids.json';
  final webRoot = env['DISMESSAGE_WEB'] ?? '../app/build/web';
  final idKey = env['DISMESSAGE_ID_KEY'];
  final legacy = env['DISMESSAGE_LEGACY_IDS'] == '1';
  final relay = await relayWithFileStore(
    dataFile,
    log: _log,
    idKey: idKey,
    acceptLegacyIds: legacy,
  );
  if (idKey == null || idKey.isEmpty) {
    // Never the key itself: only where it comes from.
    stdout.writeln(
      'Clé des IDs : fichier à côté de $dataFile. En production sans '
      'disque, définissez DISMESSAGE_ID_KEY, sinon chaque redémarrage '
      'change tous les IDs.',
    );
  }
  if (legacy) {
    stdout.writeln(
      'Anciens IDs acceptés (DISMESSAGE_LEGACY_IDS=1) : transition seulement.',
    );
  }
  final server = await serve(
    relay,
    port: port,
    webRoot: webRoot,
    ipHeader: env['DISMESSAGE_IP_HEADER'],
  );
  stdout.writeln('Dismessage relay: ws://localhost:${server.port}/ws');
  if (Directory(webRoot).existsSync()) {
    stdout.writeln('Client web     : http://localhost:${server.port}/');
  } else {
    stdout.writeln('Client web non servi par ce serveur ($webRoot).');
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
