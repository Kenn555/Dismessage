import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config.dart';
import '../../legal/legal_texts.dart';
import '../../services/link_opener.dart' as links;
import '../../widgets/dismessage_logo.dart';
import '../legal/legal_screen.dart';

/// "À propos": version, what the app keeps (nothing) and the source code.
class AboutDismessageDialog extends StatelessWidget {
  const AboutDismessageDialog({super.key, required this.openLink});

  final links.OpenLink openLink;

  static Future<void> show(BuildContext context, {links.OpenLink? openLink}) =>
      showDialog<void>(
        context: context,
        builder: (_) =>
            AboutDismessageDialog(openLink: openLink ?? links.openLink),
      );

  Future<void> _openRepository(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (await openLink(Uri.parse(kRepositoryUrl))) return;
    // No browser could take it: the link is still one paste away.
    await Clipboard.setData(const ClipboardData(text: kRepositoryUrl));
    messenger?.showSnackBar(
      const SnackBar(
        content: Text("Impossible d'ouvrir le navigateur : lien copié."),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return AlertDialog(
      key: const Key('about-dialog'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const DismessageLogo(size: 64),
            const SizedBox(height: 12),
            Text(
              'Dismessage',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              'Version $kAppVersion',
              key: const Key('about-version'),
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
            const SizedBox(height: 16),
            const Text(
              "La messagerie où l'on voit l'autre écrire en direct.",
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              "Les messages ne sont enregistrés nulle part, ni sur le serveur "
              "ni sur l'appareil : seuls vos contacts restent sur votre "
              'appareil, et les fichiers que vous acceptez dans vos '
              'téléchargements.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              key: const Key('about-github'),
              onPressed: () => _openRepository(context),
              icon: const Icon(Icons.code_rounded),
              label: const Text('Code source sur GitHub'),
            ),
            const SizedBox(height: 4),
            SelectableText(
              kRepositoryUrl.replaceFirst('https://', ''),
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                for (final doc in legalDocuments)
                  TextButton(
                    key: ValueKey('legal-${doc.slug}'),
                    onPressed: () => LegalScreen.open(context, doc),
                    child: Text(doc.title),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('about-licenses'),
          onPressed: () => showLicensePage(
            context: context,
            applicationName: 'Dismessage',
            applicationVersion: kAppVersion,
            applicationIcon: const Padding(
              padding: EdgeInsets.all(12),
              child: DismessageLogo(size: 48),
            ),
          ),
          child: const Text('Licences'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
      ],
    );
  }
}
