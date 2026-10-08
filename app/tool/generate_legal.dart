// Writes the legal pages published with the web client:
//
//   cd app && dart run tool/generate_legal.dart
//
// Run it after any change to lib/legal/legal_texts.dart (a test checks the
// pages are up to date). On GitHub Pages: <site>/legal/confidentialite.html,
// the address to give app stores as the privacy policy.
import 'dart:io';

import 'package:dismessage/legal/legal_html.dart';
import 'package:dismessage/legal/legal_texts.dart';

void main() {
  final dir = Directory('web/legal')..createSync(recursive: true);
  for (final doc in legalDocuments) {
    final file = File('${dir.path}/${doc.slug}.html');
    file.writeAsStringSync(legalPageHtml(doc));
    stdout.writeln('écrit : ${file.path}');
  }
}
