import 'dart:io';

import 'package:dismessage/features/home/about_dialog.dart';
import 'package:dismessage/features/legal/consent_gate.dart';
import 'package:dismessage/features/legal/legal_screen.dart';
import 'package:dismessage/legal/legal_html.dart';
import 'package:dismessage/legal/legal_texts.dart';
import 'package:dismessage/services/identity_service.dart';
import 'package:dismessage/services/legal_consent.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('texts', () {
    test('three documents, distinct slugs, each with its contact', () {
      expect(legalDocuments.map((d) => d.slug).toSet(), hasLength(3));
      for (final doc in legalDocuments) {
        final all = [
          doc.intro,
          for (final s in doc.sections) ...s.paragraphs,
        ].join(' ');
        expect(all, contains(kLegalContact), reason: doc.slug);
      }
    });

    test('the minimum age is stated in the terms and the policy', () {
      String all(LegalDocument doc) =>
          [for (final s in doc.sections) ...s.paragraphs].join(' ');
      expect(all(termsOfUse), contains('$kMinimumAge ans'));
      expect(all(privacyPolicy), contains('$kMinimumAge ans'));
    });

    test('the publisher and both hosts are in the legal notice', () {
      final all = [
        for (final s in legalNotice.sections) ...s.paragraphs,
      ].join(' ');
      expect(all, contains(kLegalPublisher));
      expect(all, contains('Render Services, Inc.'));
      expect(all, contains('GitHub, Inc.'));
    });
  });

  group('web pages', () {
    for (final doc in legalDocuments) {
      test('web/legal/${doc.slug}.html is up to date', () {
        final file = File('web/legal/${doc.slug}.html');
        expect(
          file.existsSync(),
          isTrue,
          reason: 'run: dart run tool/generate_legal.dart',
        );
        expect(
          file.readAsStringSync().replaceAll('\r\n', '\n'),
          legalPageHtml(doc),
          reason: 'run: dart run tool/generate_legal.dart',
        );
      });
    }

    test('self-contained, escaped, with links between the pages', () {
      final html = legalPageHtml(privacyPolicy);
      expect(html, contains('<html lang="fr">'));
      expect(html, isNot(contains('http://')));
      expect(html, isNot(contains('<script')));
      expect(html, contains('href="mailto:$kLegalContact"'));
      expect(html, contains('href="https://cnil.fr"'));
      for (final doc in legalDocuments) {
        expect(html, contains('href="${doc.slug}.html"'));
      }
      expect(html, contains('aria-current="page">${privacyPolicy.title}'));
      // Apostrophes and quotes stay text, never markup.
      expect(html, contains('l’application'));
      expect(html, contains('<li>'));
      expect(
        legalPageHtml(termsOfUse),
        contains('« Vérifier le chiffrement »'),
      );
    });
  });

  testWidgets('a legal screen shows every section and bullet', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: LegalScreen(document: privacyPolicy)),
    );
    expect(find.text(privacyPolicy.title), findsOneWidget);
    expect(find.text('Dernière mise à jour : $kLegalUpdated'), findsOneWidget);
    // Bullets of the second section, on screen from the start.
    expect(find.text('•  '), findsWidgets);
    final list = find.byKey(const ValueKey('legal-confidentialite-text'));
    for (final section in privacyPolicy.sections) {
      await tester.scrollUntilVisible(
        find.text(section.title),
        200,
        scrollable: find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text(section.title), findsOneWidget);
    }
  });

  testWidgets('"À propos" opens each legal text', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => AboutDismessageDialog.show(
              context,
              openLink: (_) async => true,
            ),
            child: const Text('ouvrir'),
          ),
        ),
      ),
    );
    for (final doc in legalDocuments) {
      await tester.tap(find.text('ouvrir'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('legal-${doc.slug}')));
      await tester.pumpAndSettle();
      expect(find.byType(LegalScreen), findsOneWidget);
      expect(find.text(doc.intro), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fermer'));
      await tester.pumpAndSettle();
    }
  });

  group('first launch', () {
    late MemoryStore store;
    late int started;

    Future<void> pumpGate(WidgetTester tester) async {
      started = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ConsentGate(
            consent: LegalConsent(store),
            onAccepted: () => started++,
            child: const Text('accueil'),
          ),
        ),
      );
    }

    setUp(() => store = MemoryStore());

    FilledButton accept(WidgetTester tester) =>
        tester.widget<FilledButton>(find.byKey(const Key('consent-accept')));

    testWidgets('age and terms both needed, then the app starts', (
      tester,
    ) async {
      await pumpGate(tester);
      expect(find.byKey(const Key('consent-screen')), findsOneWidget);
      expect(find.text('accueil'), findsNothing);
      expect(accept(tester).onPressed, isNull);

      await tester.tap(find.byKey(const Key('consent-age')));
      await tester.pump();
      expect(accept(tester).onPressed, isNull, reason: 'terms not accepted');
      await tester.tap(find.byKey(const Key('consent-terms')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('consent-accept')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('consent-accept')));
      await tester.pumpAndSettle();

      expect(find.text('accueil'), findsOneWidget);
      expect(started, 1);
      expect(store.values[LegalConsent.key], kTermsVersion);
    });

    testWidgets('the texts can be read from it', (tester) async {
      await pumpGate(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('consent-read-conditions')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('consent-read-conditions')));
      await tester.pumpAndSettle();
      expect(find.text(termsOfUse.intro), findsOneWidget);
    });

    testWidgets('accepted once: straight to the app', (tester) async {
      store.values[LegalConsent.key] = kTermsVersion;
      await pumpGate(tester);
      expect(find.text('accueil'), findsOneWidget);
      expect(started, 0, reason: 'started by main() itself');
    });

    testWidgets('new terms: asked again', (tester) async {
      store.values[LegalConsent.key] = '2000-01-01';
      await pumpGate(tester);
      expect(find.byKey(const Key('consent-screen')), findsOneWidget);
    });
  });
}
