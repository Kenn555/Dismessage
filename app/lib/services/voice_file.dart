/// Where recordings are written and how they are read back, per platform.
library;

export 'voice_file_io.dart' if (dart.library.js_interop) 'voice_file_web.dart';
