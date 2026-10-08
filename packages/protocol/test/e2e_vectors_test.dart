// Published test vectors, run on the VM and in a browser
// (`dart test -p chrome`): browsers use Web Crypto, the apps pure Dart, and
// both must agree for a web user to talk to a phone.
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

List<int> hex(String s) => [
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
];

void main() {
  test('X25519 (RFC 7748, section 6.1)', () async {
    final x25519 = X25519();
    final alice = await x25519.newKeyPairFromSeed(
      hex('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a'),
    );
    final bobPublic = SimplePublicKey(
      hex('de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f'),
      type: KeyPairType.x25519,
    );
    expect(
      (await alice.extractPublicKey()).bytes,
      hex('8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a'),
    );
    final shared = await x25519.sharedSecretKey(
      keyPair: alice,
      remotePublicKey: bobPublic,
    );
    expect(
      await shared.extractBytes(),
      hex('4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742'),
    );
  });

  test('HKDF-SHA256 (RFC 5869, test case 1)', () async {
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: SecretKey(List.filled(22, 0x0b)),
      nonce: hex('000102030405060708090a0b0c'),
      info: hex('f0f1f2f3f4f5f6f7f8f9'),
    );
    expect(
      await key.extractBytes(),
      hex('3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf'),
    );
  });

  test('ChaCha20-Poly1305 decrypts what it encrypts, tag checked', () async {
    final aead = Chacha20.poly1305Aead();
    final key = SecretKey(List.generate(32, (i) => i));
    final nonce = List.generate(12, (i) => 0x40 + i);
    final box = await aead.encrypt(
      [1, 2, 3, 4],
      secretKey: key,
      nonce: nonce,
      aad: [9],
    );
    expect(box.mac.bytes, hasLength(16));
    expect(await aead.decrypt(box, secretKey: key, aad: [9]), [1, 2, 3, 4]);
    expect(
      () => aead.decrypt(box, secretKey: key, aad: [8]),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });
}
