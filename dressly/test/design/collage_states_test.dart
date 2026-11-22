import 'package:dressly/design/ds.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ds_harness.dart';

List<Widget> _pieces() => [
  for (final c in ['Black', 'Orange', 'Green', 'White'])
    Builder(
      builder: (ctx) {
        final t = garmentTone(c, Brightness.dark);
        return ColoredBox(
          color: t.fill,
          child: Icon(Icons.checkroom, size: 64, color: t.shade),
        );
      },
    ),
];

/// Rotation (radians) of each collage piece, read from its Transform.
List<double> _angles(WidgetTester t) => t
    .widgetList<Transform>(
      find.descendant(
        of: find.byType(DsCollage),
        matching: find.byKey(DsCollage.pieceKey),
      ),
    )
    .map((w) => w.transform.storage[1].abs())
    .toList();

void main() {
  setUpAll(loadDsFonts);

  testWidgets('collage with animations disabled renders settled', (t) async {
    await t.pumpWidget(
      dsFrame(DsCollage(pieces: _pieces()), disableAnimations: true),
    );
    await t.pump();
    expect(_angles(t), hasLength(4));
    expect(_angles(t).every((a) => a == 0), isTrue);
  });

  testWidgets('collage mid-animation is rotated, then settles', (t) async {
    await t.pumpWidget(dsFrame(DsCollage(pieces: _pieces())));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(_angles(t).any((a) => a > 0.01), isTrue);
    await t.pump(
      DsCollage.totalDuration(
        4,
        const ThemeF().tokens(Brightness.dark, DsAccent.orange).motion,
      ),
    );
    await t.pump();
    expect(_angles(t).every((a) => a < 1e-6), isTrue);
  });

  testWidgets('showDsSheet shows the uppercased title and returns the value', (
    t,
  ) async {
    Future<String?>? result;
    await t.pumpWidget(
      dsFrame(
        Builder(
          builder: (c) => DsButton(
            label: 'open',
            onPressed: () => result = showDsSheet<String>(
              c,
              title: 'Trier',
              child: Builder(
                builder: (sc) => DsButton(
                  label: 'pick',
                  onPressed: () => Navigator.pop(sc, 'x'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text('TRIER'), findsOneWidget);
    await t.tap(find.text('pick'));
    await t.pumpAndSettle();
    expect(await result, 'x');
  });

  testWidgets('DsError retry calls onRetry', (t) async {
    var n = 0;
    await t.pumpWidget(
      dsFrame(
        DsError(
          message: 'Serveur injoignable',
          retryLabel: 'Réessayer',
          onRetry: () => n++,
        ),
      ),
    );
    await t.tap(find.text('Réessayer'));
    expect(n, 1);
  });

  testWidgets('DsEmpty action calls onAction', (t) async {
    var n = 0;
    await t.pumpWidget(
      dsFrame(
        DsEmpty(
          title: 'Rien ici',
          message: 'Ajoute ta première pièce.',
          actionLabel: 'Ajouter',
          onAction: () => n++,
        ),
      ),
    );
    await t.tap(find.text('Ajouter'));
    expect(n, 1);
  });

  testWidgets('skeleton is static with animations disabled', (t) async {
    await t.pumpWidget(
      dsFrame(
        const DsSkeleton(width: 100, height: 40),
        disableAnimations: true,
      ),
    );
    await t.pump();
    expect(t.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('skeleton survives animations off then on again', (t) async {
    const sk = DsSkeleton(width: 100, height: 40);
    await t.pumpWidget(dsFrame(sk));
    final state = t.state(find.byType(DsSkeleton));
    final breathing = find.descendant(
      of: find.byType(DsSkeleton),
      matching: find.byType(AnimatedBuilder),
    );
    expect(breathing, findsOneWidget);
    await t.pumpWidget(dsFrame(sk, disableAnimations: true));
    await t.pump();
    expect(breathing, findsNothing);
    // Re-enabling used to create a second ticker on a
    // SingleTickerProviderStateMixin, which asserts.
    await t.pumpWidget(dsFrame(sk));
    await t.pump();
    expect(t.takeException(), isNull);
    expect(t.state(find.byType(DsSkeleton)), same(state));
    expect(breathing, findsOneWidget);
    expect(t.binding.hasScheduledFrame, isTrue);
  });

  testWidgets('skeleton breathes when animations are on', (t) async {
    await t.pumpWidget(dsFrame(const DsSkeleton(width: 100, height: 40)));
    await t.pump();
    expect(t.binding.hasScheduledFrame, isTrue);
  });

  group('goldens', () {
    testWidgets('collage_settled', (t) async {
      await expectDsGolden(
        t,
        SizedBox(width: 388, child: DsCollage(pieces: _pieces())),
        'collage_settled',
        height: 440,
      );
    });
    testWidgets('sheet', (t) async {
      await expectDsGolden(
        t,
        const DsSheetBody(title: 'Trier par', child: SizedBox(height: 40)),
        'sheet',
        height: 160,
      );
    });
    testWidgets('empty', (t) async {
      await expectDsGolden(
        t,
        DsEmpty(
          title: 'Rien de prévu',
          message: 'Planifie une tenue pour un jour de la semaine.',
          actionLabel: 'Planifier',
          onAction: () {},
        ),
        'empty',
        height: 280,
      );
    });
    testWidgets('error', (t) async {
      await expectDsGolden(
        t,
        DsError(
          message: 'Serveur injoignable.',
          retryLabel: 'Réessayer',
          onRetry: () {},
        ),
        'error',
        height: 240,
      );
    });
    testWidgets('skeleton_grid', (t) async {
      await expectDsGolden(
        t,
        const SizedBox(width: 388, child: DsSkeleton.swatchGrid()),
        'skeleton_grid',
        height: 520,
      );
    });
  });
}
