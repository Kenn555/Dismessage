/// Opens a web link in the system browser. False if nothing could open it.
library;

export 'link_opener_io.dart'
    if (dart.library.js_interop) 'link_opener_web.dart';

/// Opens [url]; injected in tests.
typedef OpenLink = Future<bool> Function(Uri url);
