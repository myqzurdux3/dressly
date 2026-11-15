import 'package:dressly/design/ds.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/contrast.dart';

void main() {
  for (final b in Brightness.values) {
    for (final a in DsAccent.values) {
      test('F $b $a is readable', () {
        final c = const ThemeF().tokens(b, a).colors;
        expect(contrast(c.text, c.bg), greaterThanOrEqualTo(7));
        expect(contrast(c.textMuted, c.bg), greaterThanOrEqualTo(4.5));
        expect(contrast(c.textMuted, c.surface), greaterThanOrEqualTo(3));
        expect(contrast(c.onAccent, c.accent), greaterThanOrEqualTo(4.5));
        expect(contrast(c.accentText, c.bg), greaterThanOrEqualTo(3));
      });
    }
  }

  test('unknown accent name falls back to orange', () {
    expect(DsAccent.fromName('teal'), DsAccent.orange);
    expect(DsAccent.fromName(null), DsAccent.orange);
    expect(DsAccent.fromName('acid'), DsAccent.acid);
  });

  testWidgets('context.ds reads the extension', (t) async {
    late DsTokens got;
    await t.pumpWidget(
      MaterialApp(
        theme: const ThemeF().themeData(Brightness.dark, DsAccent.orange),
        home: Builder(
          builder: (c) {
            got = c.ds;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(got.colors.bg, const Color(0xFF17120F));
  });

  testWidgets('context.ds throws a clear error without the extension', (
    t,
  ) async {
    Object? error;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            try {
              c.ds;
            } catch (e) {
              error = e;
            }
            return const SizedBox();
          },
        ),
      ),
    );
    expect(error, isA<StateError>());
  });

  test('lerp interpolates colors', () {
    final d = const ThemeF().tokens(Brightness.dark, DsAccent.orange);
    final l = const ThemeF().tokens(Brightness.light, DsAccent.orange);
    expect(d.lerp(l, 0.5).colors.bg, Color.lerp(d.colors.bg, l.colors.bg, 0.5));
  });

  test('theme F pins the spec palette', () {
    final d = const ThemeF().tokens(Brightness.dark, DsAccent.orange).colors;
    final l = const ThemeF().tokens(Brightness.light, DsAccent.orange).colors;
    expect(d.bg, const Color(0xFF17120F));
    expect(d.surface, const Color(0xFF2A221C));
    expect(d.text, const Color(0xFFF1E6D6));
    expect(d.accent, const Color(0xFFFF7A3D));
    expect(l.bg, const Color(0xFFF1E6D6));
    expect(l.text, const Color(0xFF17120F));
  });
}
