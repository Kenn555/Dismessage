import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// [onLeave] when the page is left (it may be frozen in the back/forward
/// cache), [onReturn] when it is restored from that cache.
void watchPageLifecycle({
  required void Function() onLeave,
  required void Function() onReturn,
}) {
  web.window.addEventListener('pagehide', ((web.Event _) => onLeave()).toJS);
  web.window.addEventListener(
    'pageshow',
    ((web.PageTransitionEvent event) {
      if (event.persisted) onReturn();
    }).toJS,
  );
}
