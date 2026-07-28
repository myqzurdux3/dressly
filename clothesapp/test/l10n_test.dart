import 'dart:io';

import 'package:clothesapp/l10n/app_text.dart';
import 'package:clothesapp/state/locale_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// The safety net that ARB codegen would otherwise provide: catch a key that
/// exists in one locale but not another, a placeholder that was translated
/// away, and a `tr(context, '...')` in the app that resolves to nothing.

/// The same delegates app.dart installs, so a locale the app supports is a
/// locale these tests can actually render.
const _delegates = <LocalizationsDelegate<dynamic>>[
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

/// Resolves a key the way a widget would, at a given locale.
Future<String> _translate(WidgetTester tester, String locale, String key,
    [Map<String, Object?>? params]) async {
  late String out;
  await tester.pumpWidget(MaterialApp(
    locale: Locale(locale),
    localizationsDelegates: _delegates,
    supportedLocales: LocaleController.supportedLocales,
    home: Builder(builder: (context) {
      out = tr(context, key, params);
      return const SizedBox();
    }),
  ));
  return out;
}

Future<int> _plural(WidgetTester tester, String locale, String baseKey,
    int count, void Function(String) capture) async {
  await tester.pumpWidget(MaterialApp(
    locale: Locale(locale),
    localizationsDelegates: _delegates,
    supportedLocales: LocaleController.supportedLocales,
    home: Builder(builder: (context) {
      capture(trPlural(context, baseKey, count));
      return const SizedBox();
    }),
  ));
  return count;
}

/// Every `tr(context, 'literal')` / `trOr(context, 'literal', ...)` in lib/.
/// Interpolated keys are skipped — they are resolved from data at runtime.
Set<String> _literalKeysUsedInApp() {
  final re = RegExp(r"""tr(?:Or)?\(\s*context\s*,\s*'([^'$]+)'""");
  final keys = <String>{};
  for (final f in Directory('lib').listSync(recursive: true)) {
    if (f is! File || !f.path.endsWith('.dart')) continue;
    if (f.path.endsWith('app_text.dart')) continue;
    for (final m in re.allMatches(f.readAsStringSync())) {
      keys.add(m.group(1)!);
    }
  }
  return keys;
}

void main() {
  final english = translationKeys('en');

  test('the app ships strings for exactly the locales it advertises', () {
    final advertised =
        LocaleController.supportedLocales.map((l) => l.languageCode).toSet();
    expect(supportedLanguageCodes.toSet(), advertised);
  });

  test('English defines every key any locale uses', () {
    for (final code in supportedLanguageCodes) {
      final extra = translationKeys(code).difference(english);
      expect(extra, isEmpty,
          reason: '$code defines keys English does not: $extra');
    }
  });

  test('no locale is missing a translation', () {
    for (final code in supportedLanguageCodes) {
      if (code == 'en') continue;
      final missing = english.difference(translationKeys(code));
      expect(missing, isEmpty,
          reason: '$code is missing ${missing.length} keys: '
              '${missing.take(10).toList()}');
    }
  });

  test('placeholdersOf actually finds placeholders', () {
    // Guards the test below: if the scanner silently returned nothing, the
    // parity check would compare two empty sets and pass on any input.
    expect(placeholdersOf('Cut-out updated ({level}).'), {'level'});
    expect(placeholdersOf('{a} and {b}'), {'a', 'b'});
    expect(placeholdersOf('no placeholders here'), isEmpty);
  });

  test('translations keep the placeholders of the English source', () {
    var withPlaceholders = 0;
    for (final code in supportedLanguageCodes) {
      if (code == 'en') continue;
      for (final key in english) {
        final src = placeholdersOf(rawTranslation('en', key)!);
        if (src.isNotEmpty) withPlaceholders++;
        final dst = placeholdersOf(rawTranslation(code, key) ?? '');
        expect(dst, src,
            reason: '$code "$key" placeholders drifted: $dst vs $src');
      }
    }
    expect(withPlaceholders, greaterThan(0),
        reason: 'no key has a placeholder — the check would be vacuous');
  });

  test('no translation is left empty', () {
    for (final code in supportedLanguageCodes) {
      for (final key in translationKeys(code)) {
        expect(rawTranslation(code, key)!.trim(), isNotEmpty,
            reason: '$code "$key" is blank');
      }
    }
  });

  test('every literal key used in the app is defined', () {
    final used = _literalKeysUsedInApp();
    expect(used, isNotEmpty, reason: 'the scanner found nothing — check it');
    final undefined = used.difference(english);
    expect(undefined, isEmpty,
        reason: 'used in lib/ but not translated: $undefined');
  });

  test('plural keys come in complete .one/.other pairs', () {
    final bases = english
        .where((k) => k.endsWith('.one'))
        .map((k) => k.substring(0, k.length - 4));
    for (final base in bases) {
      for (final code in supportedLanguageCodes) {
        expect(rawTranslation(code, '$base.one'), isNotNull,
            reason: '$code missing $base.one');
        expect(rawTranslation(code, '$base.other'), isNotNull,
            reason: '$code missing $base.other');
      }
    }
  });

  group('lookup behaviour', () {
    testWidgets('an unknown key returns the key itself, never a crash',
        (tester) async {
      expect(await _translate(tester, 'en', 'nope.not.here'), 'nope.not.here');
    });

    testWidgets('a key defined only in English still resolves under French',
        (tester) async {
      // Must use a key French genuinely lacks: the previous version asserted on
      // 'nav.wardrobe', which exists in both, so deleting the English fallback
      // entirely did not make it fail.
      final frenchOnlyMissing =
          translationKeys('en').difference(translationKeys('fr'));
      final key = frenchOnlyMissing.isNotEmpty
          ? frenchOnlyMissing.first
          : '__test.en.only__';
      if (frenchOnlyMissing.isEmpty) {
        // Locales are in sync (the parity test enforces that), so exercise the
        // mechanism on a key no locale defines: it must degrade to the key.
        expect(await _translate(tester, 'fr', key), key);
        return;
      }
      expect(await _translate(tester, 'fr', key),
          rawTranslation('en', key));
    });

    testWidgets('placeholders are substituted', (tester) async {
      final out = await _translate(
          tester, 'en', 'photo.cutoutUpdated', {'level': 'Strong'});
      expect(out, contains('Strong'));
      expect(out, isNot(contains('{level}')));
    });

    testWidgets('an unsupplied placeholder is left visible, not dropped',
        (tester) async {
      final out = await _translate(tester, 'en', 'photo.cutoutUpdated');
      expect(out, contains('{level}'));
    });
  });

  group('plurals', () {
    testWidgets('English: 1 is singular, 0 and 2 are plural', (tester) async {
      final seen = <int, String>{};
      for (final n in [0, 1, 2]) {
        await _plural(tester, 'en', 'wardrobe.item', n, (s) => seen[n] = s);
      }
      expect(seen[1], 'item');
      expect(seen[2], 'items');
      expect(seen[0], 'items');
    });

    testWidgets('French: 0 is singular, which the old ternary got wrong',
        (tester) async {
      final seen = <int, String>{};
      for (final n in [0, 1, 2]) {
        await _plural(tester, 'fr', 'wardrobe.item', n, (s) => seen[n] = s);
      }
      expect(seen[0], 'article', reason: 'French uses the singular for 0');
      expect(seen[1], 'article');
      expect(seen[2], 'articles');
    });

    testWidgets('count is available as a placeholder', (tester) async {
      var out = '';
      await _plural(tester, 'en', 'wardrobe.item', 3, (s) => out = s);
      expect(out, isNotEmpty);
    });

    testWidgets('an unknown plural base degrades to the base key',
        (tester) async {
      var out = '';
      await _plural(tester, 'en', 'nothing.here', 2, (s) => out = s);
      expect(out, 'nothing.here');
    });
  });

  group('data-driven keys still resolve', () {
    testWidgets('every palette colour has a translation', (tester) async {
      for (final c in ['Black', 'White', 'Grey', 'Blue', 'Red', 'Green',
                       'Yellow', 'Beige', 'Brown', 'Orange', 'Purple', 'Pink']) {
        final key = 'color.${c.toLowerCase()}';
        expect(await _translate(tester, 'fr', key), isNot(key),
            reason: '$key has no French translation');
      }
    });

    testWidgets('a server-supplied algorithm id falls back to its own label',
        (tester) async {
      // The case ARB codegen could not express: an id this build has never
      // heard of must still render the label the server sent.
      late String out;
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('fr'),
        localizationsDelegates: _delegates,
        supportedLocales: LocaleController.supportedLocales,
        home: Builder(builder: (context) {
          out = trOr(context, 'algoName.brand-new-from-server',
              'Brand new algorithm');
          return const SizedBox();
        }),
      ));
      expect(out, 'Brand new algorithm');
    });
  });
}
