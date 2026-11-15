import 'package:dressly/design/garment_tones.dart';
import 'package:dressly/models/cloth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/contrast.dart';

void main() {
  for (final b in Brightness.values) {
    test('every palette colour maps to a non-neutral tone ($b)', () {
      final neutral = garmentTone('', b);
      for (final n in kColorPalette) {
        expect(garmentTone(n, b), isNot(equals(neutral)), reason: n);
      }
    });

    test('unknown and empty names fall back to neutral ($b)', () {
      expect(garmentTone('teal', b), garmentTone('', b));
    });

    test('onFill readable and shade visible on every fill ($b)', () {
      for (final n in [...kColorPalette, '']) {
        final t = garmentTone(n, b);
        expect(contrast(t.onFill, t.fill), greaterThanOrEqualTo(4.5),
            reason: '$n onFill');
        expect(contrast(t.shade, t.fill), greaterThanOrEqualTo(1.4),
            reason: '$n shade');
      }
    });
  }

  test('case-insensitive, gray is grey', () {
    expect(garmentTone('BLACK', Brightness.dark),
        garmentTone('black', Brightness.dark));
    expect(garmentTone('Gray', Brightness.dark),
        garmentTone('Grey', Brightness.dark));
  });
}
