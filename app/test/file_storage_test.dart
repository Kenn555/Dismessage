import 'dart:io';
import 'dart:typed_data';

import 'package:dismessage/services/file_storage.dart';
import 'package:dismessage/services/file_storage_io.dart';
import 'package:dismessage/widgets/file_bubble.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory downloads;
  late DesktopFileStorage storage;

  setUp(() {
    downloads = Directory.systemTemp.createTempSync('dismessage_dl_');
    storage = DesktopFileStorage(directory: () async => downloads);
  });

  tearDown(() => downloads.deleteSync(recursive: true));

  List<String> names() =>
      downloads.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();

  group('DesktopFileStorage', () {
    test('writes a .part file, renamed once complete', () async {
      final sink = await storage.create('notes.txt', 6);
      await sink.write(Uint8List.fromList('Bon'.codeUnits));
      expect(names(), ['notes.txt.part'], reason: 'hidden until complete');
      await sink.write(Uint8List.fromList('jour'.codeUnits));
      final saved = await sink.close();

      expect(names(), ['notes.txt']);
      expect(saved.name, 'notes.txt');
      expect(saved.location, 'Téléchargements');
      expect(
        File(
          '${downloads.path}${Platform.pathSeparator}notes.txt',
        ).readAsStringSync(),
        'Bonjour',
      );
    });

    test('never overwrites an existing file', () async {
      File(
        '${downloads.path}${Platform.pathSeparator}photo.jpg',
      ).writeAsStringSync('ancienne');
      final sink = await storage.create('photo.jpg', 3);
      expect(sink.name, 'photo (2).jpg');
      await sink.write(Uint8List.fromList([1, 2, 3]));
      final saved = await sink.close();
      expect(saved.name, 'photo (2).jpg');
      expect(names(), ['photo (2).jpg', 'photo.jpg']);
    });

    test('two downloads of the same name at once get distinct files', () async {
      final first = await storage.create('a.bin', 1);
      final second = await storage.create('a.bin', 1);
      expect(second.name, isNot(first.name));
      await first.close();
      await second.close();
      expect(names(), ['a (2).bin', 'a.bin']);
    });

    test('abort deletes what was written', () async {
      final sink = await storage.create('long.iso', 100);
      await sink.write(Uint8List(50));
      await sink.abort();
      expect(names(), isEmpty);
    });

    test('no Downloads folder: a clear error', () async {
      final none = DesktopFileStorage(directory: () async => null);
      expect(
        () => none.create('a', 1),
        throwsA(
          isA<FileStorageException>().having(
            (e) => e.message,
            'message',
            contains('Téléchargements'),
          ),
        ),
      );
    });
  });

  test('IoChosenFile reads the requested slices', () async {
    final file = File('${downloads.path}${Platform.pathSeparator}src.bin')
      ..writeAsBytesSync(List.generate(100, (i) => i));
    final chosen = IoChosenFile(file, 'src.bin', 100);
    expect(await chosen.read(0, 3), [0, 1, 2]);
    expect(await chosen.read(98, 2), [98, 99]);
    await chosen.close();
  });

  test('formatFileSize speaks French', () {
    expect(formatFileSize(0), '0 o');
    expect(formatFileSize(532), '532 o');
    expect(formatFileSize(1024), '1 Ko');
    expect(formatFileSize(12698), '12,4 Ko');
    expect(formatFileSize(3 * 1024 * 1024 + 200000), '3,2 Mo');
    expect(formatFileSize(512 * 1024 * 1024), '512 Mo');
    expect(formatFileSize(1288490189), '1,2 Go');
  });
}
