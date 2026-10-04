import 'dart:math';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('DismessageId.generate', () {
    test('produces 9 digits without leading zero', () {
      final rng = Random(42);
      for (var i = 0; i < 1000; i++) {
        final id = DismessageId.generate(rng);
        expect(id, matches(RegExp(r'^[1-9]\d{8}$')));
        expect(DismessageId.isValid(id), isTrue);
      }
    });

    test('secret is 32 random bytes in base64url', () {
      final a = DismessageId.generateSecret();
      final b = DismessageId.generateSecret();
      expect(a, hasLength(44));
      expect(a, isNot(b));
    });
  });

  group('DismessageId.isValid', () {
    test('rejects malformed IDs', () {
      for (final bad in [
        '',
        '12345678',
        '1234567890',
        '012345678',
        '12a456789',
        '123 456 789',
      ]) {
        expect(DismessageId.isValid(bad), isFalse, reason: bad);
      }
    });
  });

  group('format / parse', () {
    test('formats as XXX XXX XXX', () {
      expect(DismessageId.format('482913075'), '482 913 075');
    });

    test('mask hides the middle group', () {
      expect(DismessageId.mask('482913075'), '482 *** 075');
      expect(() => DismessageId.mask('12'), throwsArgumentError);
    });

    test('format rejects invalid IDs', () {
      expect(() => DismessageId.format('123'), throwsArgumentError);
    });

    test('parse accepts spaces, dashes and dots', () {
      expect(DismessageId.parse('482 913 075'), '482913075');
      expect(DismessageId.parse(' 482-913-075 '), '482913075');
      expect(DismessageId.parse('482.913.075'), '482913075');
      expect(DismessageId.parse('82 913 075'), isNull);
      expect(DismessageId.parse('abc'), isNull);
    });

    test('round trip', () {
      final rng = Random(7);
      for (var i = 0; i < 100; i++) {
        final id = DismessageId.generate(rng);
        expect(DismessageId.parse(DismessageId.format(id)), id);
      }
    });
  });
}
