import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('ServerAddress.parse', () {
    final cases = {
      'https://abc-8080.euw.devtunnels.ms':
          'wss://abc-8080.euw.devtunnels.ms/ws',
      'https://abc-8080.euw.devtunnels.ms/':
          'wss://abc-8080.euw.devtunnels.ms/ws',
      ' https://abc-8080.euw.devtunnels.ms/ws ':
          'wss://abc-8080.euw.devtunnels.ms/ws',
      'wss://example.com/ws': 'wss://example.com/ws',
      'http://192.168.1.10:8080': 'ws://192.168.1.10:8080/ws',
      'ws://localhost:8080/ws': 'ws://localhost:8080/ws',
      'example.com': 'wss://example.com/ws',
      'example.com:4443': 'wss://example.com:4443/ws',
      'localhost:8080': 'ws://localhost:8080/ws',
      '10.0.2.2:8080': 'ws://10.0.2.2:8080/ws',
    };
    cases.forEach((input, expected) {
      test('"$input"', () {
        expect(ServerAddress.parse(input).toString(), expected);
      });
    });

    test('rejects garbage', () {
      for (final bad in ['', '   ', 'ftp://x.com', 'https://', 'a b.com']) {
        expect(ServerAddress.parse(bad), isNull, reason: bad);
      }
    });
  });

  group('ServerAddress.sameOrigin', () {
    test('https page uses wss on the same host', () {
      expect(
        ServerAddress.sameOrigin(
          Uri.parse('https://abc-8080.euw.devtunnels.ms/#/'),
        ).toString(),
        'wss://abc-8080.euw.devtunnels.ms/ws',
      );
    });

    test('http page keeps its port', () {
      expect(
        ServerAddress.sameOrigin(
          Uri.parse('http://localhost:8080/'),
        ).toString(),
        'ws://localhost:8080/ws',
      );
    });
  });
}
