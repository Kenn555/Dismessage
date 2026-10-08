import 'package:flutter/material.dart';

import '../../legal/legal_texts.dart';
import '../../services/legal_consent.dart';
import '../../widgets/dismessage_logo.dart';
import 'legal_screen.dart';

/// Shows [child] once the age is confirmed and the terms accepted (first
/// launch, or after the terms changed); [onAccepted] then starts the app.
class ConsentGate extends StatefulWidget {
  const ConsentGate({
    super.key,
    required this.consent,
    required this.onAccepted,
    required this.child,
  });

  final LegalConsent consent;
  final VoidCallback onAccepted;
  final Widget child;

  @override
  State<ConsentGate> createState() => _ConsentGateState();
}

class _ConsentGateState extends State<ConsentGate> {
  bool _adult = false;
  bool _terms = false;

  Future<void> _accept() async {
    await widget.consent.accept();
    widget.onAccepted();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (widget.consent.accepted) return widget.child;
    final theme = Theme.of(context);
    final text = theme.textTheme;
    return Scaffold(
      key: const Key('consent-screen'),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: DismessageLogo(size: 72)),
                  const SizedBox(height: 16),
                  Text(
                    'Bienvenue sur Dismessage',
                    textAlign: TextAlign.center,
                    style: text.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Pas de compte, des messages chiffrés de bout en bout et '
                    'enregistrés nulle part. Avant de commencer :',
                    textAlign: TextAlign.center,
                    style: text.bodyLarge,
                  ),
                  const SizedBox(height: 20),
                  CheckboxListTile(
                    key: const Key('consent-age'),
                    value: _adult,
                    onChanged: (v) => setState(() => _adult = v ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('J’ai $kMinimumAge ans ou plus.'),
                  ),
                  CheckboxListTile(
                    key: const Key('consent-terms'),
                    value: _terms,
                    onChanged: (v) => setState(() => _terms = v ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text(
                      'J’accepte les conditions d’utilisation et j’ai lu la '
                      'politique de confidentialité.',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.center,
                    children: [
                      for (final doc in legalDocuments)
                        TextButton(
                          key: ValueKey('consent-read-${doc.slug}'),
                          onPressed: () => LegalScreen.open(context, doc),
                          child: Text(doc.title),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const Key('consent-accept'),
                    onPressed: _adult && _terms ? _accept : null,
                    child: const Text('Continuer'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
