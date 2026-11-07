import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// The browser's full screen; it may refuse (no recent user action): the view
/// then still fills the page.
Future<void> platformSetFullscreen(bool on) async {
  try {
    if (on) {
      await web.document.documentElement?.requestFullscreen().toDart;
    } else if (web.document.fullscreenElement != null) {
      await web.document.exitFullscreen().toDart;
    }
  } catch (_) {
    // See above.
  }
}
