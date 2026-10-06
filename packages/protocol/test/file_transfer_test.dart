import 'dart:math';

import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('FileChunks', () {
    test('cuts a file into full chunks and a shorter last one', () {
      const size = kFileChunkBytes * 2 + 10;
      expect(FileChunks.count(size), 3);
      expect(FileChunks.length(size, 0), kFileChunkBytes);
      expect(FileChunks.length(size, 1), kFileChunkBytes);
      expect(FileChunks.length(size, 2), 10);
      expect(FileChunks.offset(2), kFileChunkBytes * 2);
    });

    test('an exact multiple has no empty chunk; an empty file none', () {
      expect(FileChunks.count(kFileChunkBytes * 2), 2);
      expect(FileChunks.length(kFileChunkBytes * 2, 1), kFileChunkBytes);
      expect(FileChunks.count(0), 0);
      expect(FileChunks.count(1), 1);
    });

    test('a chunk fits in a frame', () {
      expect(kMaxFileChunkDataLength + 200, lessThan(kMaxFrameLength));
    });
  });

  group('OutgoingTransfer', () {
    test('sends at most the window ahead of acknowledgements', () {
      final transfer = OutgoingTransfer(kFileChunkBytes * 10);
      final first = [
        for (var i = transfer.nextChunk(); i != null; i = transfer.nextChunk())
          i,
      ];
      expect(first, List.generate(kFileWindowChunks, (i) => i));
      expect(transfer.ack(2), isTrue);
      expect(transfer.nextChunk(), kFileWindowChunks);
      expect(transfer.nextChunk(), kFileWindowChunks + 1);
      expect(transfer.nextChunk(), isNull);
      expect(transfer.ackedBytes, kFileChunkBytes * 2);
    });

    test('is done once every chunk is acknowledged', () {
      const size = kFileChunkBytes + 5;
      final transfer = OutgoingTransfer(size);
      expect(transfer.nextChunk(), 0);
      expect(transfer.nextChunk(), 1);
      expect(transfer.nextChunk(), isNull);
      expect(transfer.ack(1), isTrue);
      expect(transfer.done, isFalse);
      expect(transfer.ack(2), isTrue);
      expect(transfer.done, isTrue);
      expect(transfer.ackedBytes, size);
    });

    test('refuses impossible acknowledgements', () {
      final transfer = OutgoingTransfer(kFileChunkBytes * 3)..nextChunk();
      expect(transfer.ack(2), isFalse, reason: 'never sent');
      expect(transfer.ack(1), isTrue);
      expect(transfer.ack(0), isFalse, reason: 'going back');
    });

    test('an empty file is done on the first acknowledgement', () {
      final transfer = OutgoingTransfer(0);
      expect(transfer.nextChunk(), isNull);
      expect(transfer.ack(0), isTrue);
      expect(transfer.done, isTrue);
    });
  });

  group('IncomingTransfer', () {
    test('accepts chunks in order with their exact length', () {
      const size = kFileChunkBytes + 7;
      final transfer = IncomingTransfer(size);
      expect(transfer.accept(0, kFileChunkBytes), isTrue);
      expect(transfer.complete, isFalse);
      expect(transfer.accept(1, 7), isTrue);
      expect(transfer.complete, isTrue);
      expect(transfer.receivedBytes, size);
      expect(transfer.accept(2, 1), isFalse, reason: 'already complete');
    });

    test('refuses a chunk out of order or of the wrong length', () {
      expect(IncomingTransfer(kFileChunkBytes * 2).accept(1, 1), isFalse);
      expect(IncomingTransfer(kFileChunkBytes * 2).accept(0, 10), isFalse);
      expect(IncomingTransfer(10).accept(0, 11), isFalse);
    });

    test('sender and receiver agree on random sizes', () {
      final random = Random(7);
      for (var n = 0; n < 200; n++) {
        final size = random.nextInt(kFileChunkBytes * 6);
        final out = OutgoingTransfer(size);
        final into = IncomingTransfer(size);
        var guard = 0;
        while (!out.done) {
          final sent = <int>[];
          for (var i = out.nextChunk(); i != null; i = out.nextChunk()) {
            sent.add(i);
          }
          for (final i in sent) {
            expect(into.accept(i, FileChunks.length(size, i)), isTrue);
          }
          expect(out.ack(into.receivedChunks), isTrue);
          expect(++guard, lessThan(10000));
        }
        expect(into.complete, isTrue);
        expect(into.receivedBytes, size);
      }
    });
  });

  group('FileNames', () {
    test('keeps an ordinary name', () {
      expect(
        FileNames.sanitize('Photo de vacances.JPG'),
        'Photo de vacances.JPG',
      );
      expect(
        FileNames.sanitize('Présentation 😀.pptx'),
        'Présentation 😀.pptx',
      );
    });

    test('drops any path', () {
      expect(FileNames.sanitize('../../Windows/system.ini'), 'system.ini');
      expect(FileNames.sanitize(r'C:\Users\x\évil.bat'), 'évil.bat');
    });

    test('replaces forbidden characters', () {
      expect(FileNames.sanitize('a<b>c:d"e|f?g*h.txt'), 'a_b_c_d_e_f_g_h.txt');
      expect(FileNames.sanitize('tab\there'), 'tab_here');
    });

    test('no hidden, empty or reserved name', () {
      expect(FileNames.sanitize('.bashrc'), 'bashrc');
      expect(FileNames.sanitize('nom. . .'), 'nom');
      expect(FileNames.sanitize('...'), FileNames.fallback);
      expect(FileNames.sanitize('/'), FileNames.fallback);
      expect(FileNames.sanitize('CON.txt'), '_CON.txt');
      expect(FileNames.sanitize('lpt1'), '_lpt1');
      expect(FileNames.sanitize('console.txt'), 'console.txt');
    });

    test('a too long name keeps its extension', () {
      final name = '${'é' * 300}.pdf';
      final safe = FileNames.sanitize(name);
      expect(safe.length, kMaxFileNameLength);
      expect(safe, endsWith('.pdf'));
    });

    test('never splits an emoji when cutting', () {
      final safe = FileNames.sanitize('x${'😀' * 200}');
      expect(safe.length, lessThanOrEqualTo(kMaxFileNameLength));
      final last = safe.codeUnitAt(safe.length - 1);
      expect(last >= 0xD800 && last <= 0xDBFF, isFalse);
    });

    test('unique adds a number before the extension', () {
      final existing = {'a.txt', 'a (2).txt', 'notes'};
      expect(FileNames.unique('b.txt', existing.contains), 'b.txt');
      expect(FileNames.unique('a.txt', existing.contains), 'a (3).txt');
      expect(FileNames.unique('notes', existing.contains), 'notes (2)');
    });

    test('validity in frames', () {
      expect(FileNames.isValid('a.txt'), isTrue);
      expect(FileNames.isValid(''), isFalse);
      expect(FileNames.isValid('a\nb'), isFalse);
      expect(FileNames.isValid('x' * (kMaxFileNameLength + 1)), isFalse);
    });
  });
}
