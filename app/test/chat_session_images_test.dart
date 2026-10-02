import 'dart:typed_data';

import 'package:dismessage/services/chat_session.dart';
import 'package:dismessage/services/image_codec.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

final picture = EncodedImage(
  bytes: Uint8List.fromList(List.generate(5000, (i) => i % 251)),
  width: 1280,
  height: 960,
  preview: Uint8List.fromList([1, 2, 3, 4, 5]),
);

void main() {
  late ChatSession alice;
  late ChatSession bob;
  late List<Frame> wire;

  setUp(() {
    wire = [];
    // Two sessions connected by a fake relay that records every frame.
    alice = ChatSession(
      sid: 's',
      peer: '222222222',
      send: (f) {
        wire.add(f);
        bob.receive(f as RelayedFrame);
      },
    );
    bob = ChatSession(
      sid: 's',
      peer: '111111111',
      send: (f) {
        wire.add(f);
        alice.receive(f as RelayedFrame);
      },
    );
  });

  test('only the blurred preview travels until the image is opened', () {
    final sent = alice.sendImage(picture)!;
    expect(sent.status, ImageStatus.sent);
    expect(wire.single, isA<ImageOfferFrame>());
    expect(wire.whereType<ImageDataFrame>(), isEmpty);

    final received = bob.messages.single as ChatImage;
    expect(received.status, ImageStatus.blurred);
    expect(received.bytes, isNull, reason: 'no full image before opening');
    expect(received.preview, picture.preview);
    expect((received.width, received.height), (1280, 960));
  });

  test('opening fetches the image and tells the sender', () {
    final sent = alice.sendImage(picture)!;
    final received = bob.messages.single as ChatImage;

    bob.openImage(received);

    expect(wire.whereType<ImageRequestFrame>(), hasLength(1));
    expect(wire.whereType<ImageDataFrame>(), hasLength(1));
    expect(received.status, ImageStatus.opened);
    expect(received.bytes, picture.bytes);
    expect(sent.status, ImageStatus.opened, reason: '"Ouverte" receipt');
  });

  test('opening twice does not transfer twice', () {
    alice.sendImage(picture);
    final received = bob.messages.single as ChatImage;
    bob.openImage(received);
    bob.openImage(received);
    expect(wire.whereType<ImageDataFrame>(), hasLength(1));
  });

  test('unsolicited image data is ignored', () {
    alice.sendImage(picture);
    final received = bob.messages.single as ChatImage;
    bob.receive(ImageDataFrame(sid: 's', img: received.id, data: 'AAAA'));
    expect(received.bytes, isNull);
    expect(received.status, ImageStatus.blurred);
  });

  test('requests for unknown images are ignored', () {
    alice.receive(const ImageRequestFrame(sid: 's', img: '0123456789abcdef'));
    expect(wire, isEmpty);
  });

  test('if the sender left, the image becomes unavailable', () {
    alice.sendImage(picture);
    final received = bob.messages.single as ChatImage;
    bob.markPeerLeft();
    bob.openImage(received);
    expect(received.status, ImageStatus.unavailable);
    expect(wire.whereType<ImageRequestFrame>(), isEmpty);
  });

  test('a pending opening fails cleanly when the sender leaves', () {
    // Sender that never answers.
    final lonely = ChatSession(sid: 's', peer: '111111111', send: wire.add);
    lonely.receive(
      const ImageOfferFrame(
        sid: 's',
        img: '0123456789abcdef',
        width: 10,
        height: 10,
        preview: 'AQID',
      ),
    );
    final image = lonely.messages.single as ChatImage;
    lonely.openImage(image);
    expect(image.status, ImageStatus.loading);
    lonely.markPeerLeft();
    expect(image.status, ImageStatus.unavailable);
  });

  test('text and images keep their order', () {
    alice.updateDraft('Regarde :');
    alice.sendMessage();
    alice.sendImage(picture);
    expect(bob.messages.map((e) => e.runtimeType), [ChatMessage, ChatImage]);
  });

  test('cannot send an image once the peer left', () {
    alice.markPeerLeft();
    expect(alice.sendImage(picture), isNull);
    expect(wire, isEmpty);
  });
}
