import 'package:dismessage/widgets/live_draft_bubble.dart';
import 'package:dismessage/widgets/typing_dots.dart';
import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(String text) => MaterialApp(
  home: Scaffold(body: LiveDraftBubble(text: text)),
);

String visibleText(WidgetTester tester) => tester
    .widget<RichText>(
      find
          .descendant(
            of: find.byKey(const Key('live-draft-text')),
            matching: find.byType(RichText),
          )
          .first,
    )
    .text
    .toPlainText(includePlaceholders: false);

Finder dotsInsideText() => find.descendant(
  of: find.byKey(const Key('live-draft-text')),
  matching: find.byType(TypingDots),
);

const pause = Duration(milliseconds: kPauseDotsMs);

void main() {
  testWidgets('empty draft renders nothing', (tester) async {
    await tester.pumpWidget(host(''));
    expect(find.byKey(const Key('live-draft-text')), findsNothing);
    await tester.pump(pause * 2);
    expect(find.byType(TypingDots), findsNothing);
  });

  testWidgets('no dots while the peer is typing', (tester) async {
    await tester.pumpWidget(host('B'));
    for (final text in ['Bo', 'Bon', 'Bonj', 'Bonjo', 'Bonjou', 'Bonjour']) {
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpWidget(host(text));
      expect(find.byType(TypingDots), findsNothing);
    }
    await tester.pump(const Duration(milliseconds: 200));
    expect(visibleText(tester), 'Bonjour');
    expect(find.byType(TypingDots), findsNothing);
  });

  testWidgets('dots appear after a pause, right after the text', (
    tester,
  ) async {
    await tester.pumpWidget(host('Salut'));
    await tester.pump(pause - const Duration(milliseconds: 50));
    expect(find.byType(TypingDots), findsNothing);

    await tester.pump(const Duration(milliseconds: 100));
    expect(
      dotsInsideText(),
      findsOneWidget,
      reason: 'dots must be inline, inside the same rich text',
    );

    // Typing again hides them immediately.
    await tester.pumpWidget(host('Salut !'));
    expect(find.byType(TypingDots), findsNothing);
    await tester.pump(pause + const Duration(milliseconds: 50));
    expect(dotsInsideText(), findsOneWidget);
  });

  testWidgets('a burst of characters is rolled out progressively', (
    tester,
  ) async {
    await tester.pumpWidget(host(''));
    const burst = 'Ceci arrive en un seul paquet réseau';
    await tester.pumpWidget(host(burst));
    // Next frame: only part of the burst is visible.
    await tester.pump(const Duration(milliseconds: 16));
    final partial = visibleText(tester);
    expect(partial.length, lessThan(burst.length));
    expect(burst.startsWith(partial), isTrue);

    await tester.pump(LiveDraftBubble.rollWindow);
    await tester.pump(LiveDraftBubble.fadeDuration);
    expect(visibleText(tester), burst);
  });

  testWidgets('new characters fade in', (tester) async {
    await tester.pumpWidget(host('ab'));
    await tester.pumpWidget(host('abc'));
    await tester.pump(const Duration(milliseconds: 16));
    final leaves = <TextSpan>[];
    tester
        .widget<RichText>(
          find
              .descendant(
                of: find.byKey(const Key('live-draft-text')),
                matching: find.byType(RichText),
              )
              .first,
        )
        .text
        .visitChildren((span) {
          if (span is TextSpan && span.text != null) leaves.add(span);
          return true;
        });
    final fresh = leaves.last;
    expect(fresh.text, 'c');
    expect(fresh.style?.color?.a, lessThan(1));
  });

  testWidgets('emoji are never split while rolling out', (tester) async {
    await tester.pumpWidget(host(''));
    const text = '😀😀😀😀😀😀😀😀😀😀👍';
    await tester.pumpWidget(host(text));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 8));
      final visible = visibleText(tester);
      expect(
        visible.runes.every((r) => r < 0xD800 || r > 0xDFFF),
        isTrue,
        reason: 'lone surrogate in "$visible"',
      );
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(visibleText(tester), text);
  });

  testWidgets('deletions apply immediately', (tester) async {
    await tester.pumpWidget(host('Bonjour'));
    await tester.pumpWidget(host('Bonj'));
    await tester.pump();
    expect(visibleText(tester), 'Bonj');
    await tester.pumpWidget(host(''));
    await tester.pump();
    expect(find.byKey(const Key('live-draft-text')), findsNothing);
  });
}
