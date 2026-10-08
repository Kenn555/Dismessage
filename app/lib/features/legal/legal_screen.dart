import 'package:flutter/material.dart';

import '../../legal/legal_texts.dart';

/// One legal text (mentions légales, confidentialité, conditions).
class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key, required this.document});

  final LegalDocument document;

  static Future<void> open(BuildContext context, LegalDocument document) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => LegalScreen(document: document),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final muted = theme.colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: Text(document.title)),
      body: SafeArea(
        child: SelectionArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                key: ValueKey('legal-${document.slug}-text'),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  Text(
                    'Dernière mise à jour : $kLegalUpdated',
                    style: text.bodySmall?.copyWith(color: muted),
                  ),
                  const SizedBox(height: 12),
                  Text(document.intro, style: text.bodyLarge),
                  for (final section in document.sections) ...[
                    const SizedBox(height: 24),
                    Text(
                      section.title,
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    for (final paragraph in section.paragraphs)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: paragraph.startsWith('- ')
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('•  '),
                                  Expanded(child: Text(paragraph.substring(2))),
                                ],
                              )
                            : Text(paragraph),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
