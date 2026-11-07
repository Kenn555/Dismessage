/// Puts the whole window or page in full screen, for the live camera view.
library;

export 'window_fullscreen_io.dart'
    if (dart.library.js_interop) 'window_fullscreen_web.dart';
