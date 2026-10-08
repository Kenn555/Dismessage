import 'package:web/web.dart' as web;

/// A new tab (`noopener`: the site cannot reach back into this page).
Future<bool> openLink(Uri url) async {
  web.window.open(url.toString(), '_blank', 'noopener');
  return true;
}
