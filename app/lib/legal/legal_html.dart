import 'legal_texts.dart';

/// The web page of [doc], self-contained (no external resource): written to
/// `web/legal/` by `tool/generate_legal.dart`, kept in sync by a test.
String legalPageHtml(LegalDocument doc) {
  final out = StringBuffer()
    ..writeln('<!DOCTYPE html>')
    ..writeln('<html lang="fr">')
    ..writeln('<head>')
    ..writeln('<meta charset="UTF-8">')
    ..writeln(
      '<meta name="viewport" content="width=device-width, initial-scale=1">',
    )
    ..writeln('<title>${_escape(doc.title)} · Dismessage</title>')
    ..writeln('<link rel="icon" type="image/png" href="../favicon.png">')
    ..writeln('<style>$_css</style>')
    ..writeln('</head>')
    ..writeln('<body>')
    ..writeln('<header><a class="brand" href="../">Dismessage</a><nav>');
  for (final other in legalDocuments) {
    final current = other.slug == doc.slug ? ' aria-current="page"' : '';
    out.writeln(
      '<a href="${other.slug}.html"$current>${_escape(other.title)}</a>',
    );
  }
  out
    ..writeln('</nav></header>')
    ..writeln('<main>')
    ..writeln('<h1>${_escape(doc.title)}</h1>')
    ..writeln('<p class="updated">Dernière mise à jour : $kLegalUpdated</p>')
    ..writeln('<p class="intro">${_inline(doc.intro)}</p>');
  for (final section in doc.sections) {
    out.writeln('<h2>${_escape(section.title)}</h2>');
    var inList = false;
    for (final paragraph in section.paragraphs) {
      final bullet = paragraph.startsWith('- ');
      if (bullet && !inList) out.writeln('<ul>');
      if (!bullet && inList) out.writeln('</ul>');
      inList = bullet;
      out.writeln(
        bullet
            ? '<li>${_inline(paragraph.substring(2))}</li>'
            : '<p>${_inline(paragraph)}</p>',
      );
    }
    if (inList) out.writeln('</ul>');
  }
  out
    ..writeln('</main>')
    ..writeln('</body>')
    ..writeln('</html>');
  return out.toString();
}

String _escape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// Escapes, then turns the e-mail address and known sites into links.
String _inline(String text) => _escape(text).replaceAllMapped(_links, (m) {
  final found = m[0]!;
  final href = found.contains('@') ? 'mailto:$found' : 'https://$found';
  return '<a href="$href">$found</a>';
});

final _links = RegExp(
  [
    RegExp.escape(kLegalContact),
    r'github\.com/Kenn555/Dismessage',
    r'internet-signalement\.gouv\.fr',
    r'cnil\.fr',
    r'render\.com',
    r'github\.com',
  ].join('|'),
);

const _css = '''
:root{--bg:#f7f7fb;--surface:#ffffff;--text:#1d1b2e;--muted:#5d5a72;--brand:#5b5bd6;--line:#e4e2f0}
@media (prefers-color-scheme:dark){:root{--bg:#121120;--surface:#1c1b2e;--text:#ecebf7;--muted:#a9a6c2;--brand:#a5a4ff;--line:#2e2c45}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:16px/1.6 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
header{background:linear-gradient(135deg,#5b5bd6,#8b5cf6);padding:16px;display:flex;flex-wrap:wrap;gap:8px 20px;align-items:center}
header a{color:#fff;text-decoration:none}
.brand{font-weight:800;font-size:20px;letter-spacing:-.3px;margin-right:auto}
nav{display:flex;flex-wrap:wrap;gap:6px 16px}
nav a{opacity:.85;font-size:15px}
nav a[aria-current]{opacity:1;font-weight:700;text-decoration:underline;text-underline-offset:4px}
main{max-width:760px;margin:24px 16px;padding:24px 16px;background:var(--surface);border:1px solid var(--line);border-radius:16px}
@media (min-width:800px){main{margin:24px auto;padding:32px 40px}}
h1{margin:0 0 4px;font-size:28px;line-height:1.25}
h2{margin:28px 0 8px;font-size:19px}
.updated{margin:0 0 16px;color:var(--muted);font-size:14px}
.intro{font-size:17px}
ul{padding-left:22px}
li{margin:4px 0}
a{color:var(--brand);overflow-wrap:anywhere}
''';
