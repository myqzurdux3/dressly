import 'dart:io';

import 'package:dressly/design/ds.dart';
import 'package:flutter_test/flutter_test.dart';

/// Goldens load the fonts by hand, so they cannot notice a family missing
/// from pubspec.yaml; the app then silently falls back to a system font.
void main() {
  test('every design-system font family is declared and its files exist', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final family in [DsFonts.display, DsFonts.body, DsFonts.mono]) {
      expect(pubspec, contains('- family: $family'), reason: family);
    }
    final assets = RegExp(r'- asset: (assets/fonts/\S+)')
        .allMatches(pubspec)
        .map((m) => m.group(1)!);
    for (final a in assets) {
      expect(File(a).existsSync(), isTrue, reason: a);
    }
  });
}
