import 'dart:math';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:test/test.dart';

void expectRoundTrip(String a, String b) {
  final op = TextDiff.compute(a, b);
  if (a == b) {
    expect(op, isNull);
    return;
  }
  expect(TextDiff.apply(a, op!), b, reason: '"$a" -> "$b" via $op');
}

bool isWellFormed(String s) {
  for (var i = 0; i < s.length; i++) {
    final u = s.codeUnitAt(i);
    if (u >= 0xD800 && u <= 0xDBFF) {
      if (i + 1 >= s.length) return false;
      final next = s.codeUnitAt(++i);
      if (next < 0xDC00 || next > 0xDFFF) return false;
    } else if (u >= 0xDC00 && u <= 0xDFFF) {
      return false;
    }
  }
  return true;
}

void main() {
  group('TextDiff.compute', () {
    test('equal strings give null', () {
      expect(TextDiff.compute('abc', 'abc'), isNull);
    });

    test('append', () {
      expect(
        TextDiff.compute('Bonj', 'Bonjour'),
        const EditOp(pos: 4, del: 0, ins: 'our'),
      );
    });

    test('backspace', () {
      expect(
        TextDiff.compute('Bonjour', 'Bonjou'),
        const EditOp(pos: 6, del: 1, ins: ''),
      );
    });

    test('replace in the middle', () {
      expect(
        TextDiff.compute('le chat noir', 'le chien noir'),
        const EditOp(pos: 5, del: 2, ins: 'ien'),
      );
    });

    test('paste over everything', () {
      expect(
        TextDiff.compute('abc', 'xyz'),
        const EditOp(pos: 0, del: 3, ins: 'xyz'),
      );
    });

    test('insertion of repeated char is minimal', () {
      final op = TextDiff.compute('aaa', 'aaaa')!;
      expect(op.del, 0);
      expect(op.ins, 'a');
    });

    test('never splits a surrogate pair', () {
      // Two emoji sharing the same high surrogate.
      const a = '😀';
      const b = '😃';
      final op = TextDiff.compute('x$a', 'x$b')!;
      expect(op.pos, 1);
      expect(op.ins, b);
      expect(op.del, 2);

      final op2 = TextDiff.compute('${a}y', '${b}y')!;
      expect(op2.pos, 0);
      expect(op2.ins, b);
    });

    test('targeted round trips', () {
      final cases = [
        ['', 'Salut'],
        ['Salut', ''],
        ['Salut', 'Salut !'],
        ['Salut !', 'Salut, ça va ?'],
        ['café', 'cafés'],
        ['👋 hello', '👋👋 hello'],
        ['🇫🇷', '🇧🇪'],
        ['a\nb', 'a\n\nb'],
      ];
      for (final c in cases) {
        expectRoundTrip(c[0], c[1]);
      }
    });
  });

  group('TextDiff.apply', () {
    test('rejects out of range ops', () {
      expect(
        () => TextDiff.apply('abc', const EditOp(pos: 4, del: 0, ins: 'x')),
        throwsRangeError,
      );
      expect(
        () => TextDiff.apply('abc', const EditOp(pos: 2, del: 2, ins: '')),
        throwsRangeError,
      );
    });
  });

  test('randomized invariant: apply(old, compute(old, new)) == new', () {
    final rng = Random(1234);
    const alphabet = ['a', 'b', ' ', 'é', '😀', '👍', '\n'];
    String randomText() => List.generate(
      rng.nextInt(12),
      (_) => alphabet[rng.nextInt(alphabet.length)],
    ).join();
    String mutate(String s) {
      final chars = s.runes.map(String.fromCharCode).toList();
      for (var i = rng.nextInt(4); i >= 0; i--) {
        final at = chars.isEmpty ? 0 : rng.nextInt(chars.length + 1);
        if (rng.nextBool() || chars.isEmpty) {
          chars.insert(at, alphabet[rng.nextInt(alphabet.length)]);
        } else {
          chars.removeAt(at.clamp(0, chars.length - 1));
        }
      }
      return chars.join();
    }

    for (var i = 0; i < 1000; i++) {
      final a = randomText();
      final b = rng.nextBool() ? mutate(a) : randomText();
      expectRoundTrip(a, b);
      final op = TextDiff.compute(a, b);
      if (op != null) {
        // The inserted text must be well-formed UTF-16 (no lone surrogate).
        expect(isWellFormed(op.ins), isTrue, reason: op.toString());
      }
    }
  });

  test('EditOp JSON round trip and validation', () {
    const op = EditOp(pos: 3, del: 1, ins: 'é');
    expect(EditOp.fromJson(op.toJson()), op);
    expect(
      () => EditOp.fromJson({'pos': -1, 'del': 0, 'ins': ''}),
      throwsFormatException,
    );
    expect(() => EditOp.fromJson('x'), throwsFormatException);
  });
}
