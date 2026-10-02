import 'dart:async';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Records what the app sends.
class RecordingSink implements WebSocketSink {
  final sent = <Frame>[];

  @override
  void add(Object? data) => sent.add(Frame.decode(data));

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A connected channel whose server side is driven by the test.
class ScriptedChannel implements WebSocketChannel {
  final server = StreamController<Object?>();
  @override
  final RecordingSink sink = RecordingSink();

  void receive(Frame frame) => server.add(frame.encode());

  @override
  Future<void> get ready async {}

  @override
  Stream<Object?> get stream => server.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A handshake that never completes (blocked by a proxy, firewall…).
class HangingChannel implements WebSocketChannel {
  @override
  Future<void> get ready => Completer<void>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
