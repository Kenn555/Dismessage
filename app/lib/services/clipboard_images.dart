/// Images and files pasted into the input: Ctrl+V on Windows (read here, the
/// text field only knows text), the browser's own paste on the web. Android
/// keyboards insert images through the text field itself
/// (`contentInsertionConfiguration`).
library;

import 'attachments.dart';

export 'clipboard_images_io.dart'
    if (dart.library.js_interop) 'clipboard_images_web.dart';

/// Where pasted content comes from; injected in tests.
abstract class ClipboardImages {
  /// Whether the app reads the clipboard itself on Ctrl+V ([read]).
  bool get readsOnPasteKey;

  /// What the clipboard holds besides text: a copied picture, copied files of
  /// any type; empty if none.
  Future<Attachments> read();

  /// What was pasted where the platform handles the paste (the browser).
  Stream<Attachments> get pasted;
}

/// No paste outside the text field (Android, tests).
class NoClipboardImages implements ClipboardImages {
  const NoClipboardImages();

  @override
  bool get readsOnPasteKey => false;

  @override
  Future<Attachments> read() async => const Attachments();

  @override
  Stream<Attachments> get pasted => const Stream.empty();
}
