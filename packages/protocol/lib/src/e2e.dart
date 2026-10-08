import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'constants.dart';
import 'frames.dart';

/// A sealed frame that cannot be opened: wrong key, altered, replayed or
/// out of order, or not a conversation frame once opened.
class E2eException implements Exception {
  const E2eException(this.message);
  final String message;
  @override
  String toString() => 'E2eException: $message';
}

/// End-to-end encryption of one conversation: the relay only ever sees
/// `key_offer` (public keys) and `sealed` (ciphertext).
///
/// - Each side makes a fresh X25519 key pair for the conversation and sends
///   its public key ([offer]). Nothing is kept once it ends.
/// - Both derive the same shared secret, then one key per direction with
///   HKDF-SHA256 (salt: the `sid`; info: sender then receiver public key).
/// - Every conversation frame travels as `sealed`: its JSON encrypted with
///   ChaCha20-Poly1305, nonce = the frame counter `n` (never reused: a key
///   per direction and per conversation), the `sid` authenticated alongside.
///   `n` must grow: a replayed or reordered frame is refused.
/// - The relay could still put itself in the middle of the key exchange:
///   [safetyCode], the same on both sides only without such an attacker,
///   lets the two people compare it (aloud, on another channel).
class E2eSession {
  E2eSession(this.sid);

  final String sid;

  static final _x25519 = X25519();
  static final _aead = Chacha20.poly1305Aead();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  late final Future<SimpleKeyPair> _keyPair = _x25519.newKeyPair();
  late final Future<List<int>> _publicKey = _keyPair.then(
    (pair) async => (await pair.extractPublicKey()).bytes,
  );
  final _ready = Completer<void>();
  SecretKey? _sendKey;
  SecretKey? _receiveKey;
  List<int>? _peerKey;
  int _sent = 0;
  int _received = 0;

  /// Both keys are known: frames can be sealed and opened.
  bool get isReady => _ready.isCompleted;

  /// Completes once the peer's key has been accepted.
  Future<void> get ready => _ready.future;

  /// Our public key, to send first.
  Future<KeyOfferFrame> offer() async =>
      KeyOfferFrame(sid: sid, key: base64Url.encode(await _publicKey));

  /// Takes the peer's public key. Only the first one counts: a later one
  /// (a relay trying to switch keys mid-conversation) is refused.
  Future<void> accept(KeyOfferFrame offer) async {
    if (_peerKey != null) throw const E2eException('key already set');
    final List<int> peerKey;
    try {
      peerKey = base64Url.decode(offer.key);
    } on FormatException {
      throw const E2eException('invalid key');
    }
    if (peerKey.length != 32) throw const E2eException('invalid key');
    _peerKey = peerKey;
    final SecretKey shared;
    try {
      shared = await _x25519.sharedSecretKey(
        keyPair: await _keyPair,
        remotePublicKey: SimplePublicKey(peerKey, type: KeyPairType.x25519),
      );
    } on Object {
      // Browsers (Web Crypto) refuse a low-order point themselves.
      throw const E2eException('weak key');
    }
    // A low-order point gives an all-zero secret, known to everyone.
    if ((await shared.extractBytes()).every((b) => b == 0)) {
      throw const E2eException('weak key');
    }
    final mine = await _publicKey;
    _sendKey = await _derive(shared, mine, peerKey);
    _receiveKey = await _derive(shared, peerKey, mine);
    _ready.complete();
  }

  Future<SecretKey> _derive(
    SecretKey shared,
    List<int> sender,
    List<int> receiver,
  ) => _hkdf.deriveKey(
    secretKey: shared,
    nonce: utf8.encode(sid),
    info: [...utf8.encode('dismessage-e2e-v1'), ...sender, ...receiver],
  );

  /// 4 zero bytes then [n] on 8 bytes, big-endian. Two 32-bit halves:
  /// web builds have no 64-bit accessor.
  static List<int> _nonce(int n) => (ByteData(12)
        ..setUint32(4, n ~/ 0x100000000)
        ..setUint32(8, n % 0x100000000))
      .buffer
      .asUint8List();

  /// Encrypts [frame] (of this conversation). Waits for the key exchange.
  Future<SealedFrame> seal(RelayedFrame frame) async {
    if (frame.sid != sid || frame is SealedFrame || frame is KeyOfferFrame) {
      throw ArgumentError.value(frame.type, 'frame', 'not sealable here');
    }
    await ready;
    final n = ++_sent;
    final box = await _aead.encrypt(
      utf8.encode(frame.encode()),
      secretKey: _sendKey!,
      nonce: _nonce(n),
      aad: utf8.encode(sid),
    );
    return SealedFrame(
      sid: sid,
      n: n,
      data: base64.encode([...box.cipherText, ...box.mac.bytes]),
    );
  }

  /// Decrypts a frame from the peer, in order.
  Future<RelayedFrame> open(SealedFrame sealed) async {
    if (!isReady) throw const E2eException('no key yet');
    if (sealed.sid != sid) throw const E2eException('other conversation');
    if (sealed.n <= _received) throw const E2eException('replayed frame');
    final bytes = base64.decode(sealed.data);
    if (bytes.length < 16) throw const E2eException('too short');
    final List<int> plain;
    try {
      plain = await _aead.decrypt(
        SecretBox(
          bytes.sublist(0, bytes.length - 16),
          nonce: _nonce(sealed.n),
          mac: Mac(bytes.sublist(bytes.length - 16)),
        ),
        secretKey: _receiveKey!,
        aad: utf8.encode(sid),
      );
    } on SecretBoxAuthenticationError {
      throw const E2eException('altered or wrong key');
    }
    _received = sealed.n;
    if (plain.length > kMaxInnerFrameLength) {
      throw const E2eException('too large');
    }
    final Frame frame;
    try {
      frame = Frame.decode(utf8.decode(plain));
    } on FormatException catch (e) {
      throw E2eException('invalid frame inside: ${e.message}');
    }
    if (frame is! RelayedFrame ||
        frame is SealedFrame ||
        frame is KeyOfferFrame ||
        frame.sid != sid) {
      throw const E2eException('not a conversation frame');
    }
    return frame;
  }

  /// 20 digits in groups of 5, the same on both sides when nobody sits in
  /// the middle of the key exchange (null until it is done).
  Future<String?> safetyCode() async {
    final peer = _peerKey;
    if (peer == null) return null;
    final mine = await _publicKey;
    // Same order on both sides: the smaller key first.
    final keys = [mine, peer]..sort(_compare);
    final hash = await Sha256().hash([
      ...utf8.encode('dismessage-safety-v1'),
      ...keys[0],
      ...keys[1],
    ]);
    var digits = '';
    for (var i = 0; digits.length < 20; i += 4) {
      final chunk = ByteData.sublistView(
        Uint8List.fromList(hash.bytes),
        i,
        i + 4,
      ).getUint32(0);
      digits += (chunk % 100000).toString().padLeft(5, '0');
    }
    return [
      for (var i = 0; i < 20; i += 5) digits.substring(i, i + 5),
    ].join(' ');
  }

  static int _compare(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return 0;
  }
}
