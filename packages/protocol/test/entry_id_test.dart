import 'dart:math';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('generated IDs are valid and distinct', () {
    final random = Random(1);
    final ids = {for (var i = 0; i < 1000; i++) EntryId.generate(random)};
    expect(ids, hasLength(1000));
    expect(ids.every(EntryId.isValid), isTrue);
  });

  test('rejects anything but short lowercase hex', () {
    for (final bad in ['', 'abc', 'ABCDEF0123', '../etc/passwd', 'g' * 16]) {
      expect(EntryId.isValid(bad), isFalse, reason: bad);
    }
    expect(EntryId.isValid('0' * 33), isFalse);
  });
}
