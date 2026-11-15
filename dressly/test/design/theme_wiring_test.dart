import 'package:dressly/design/ds.dart';
import 'package:dressly/screens/settings/settings_screen.dart';
import 'package:dressly/state/gen_prefs_controller.dart';
import 'package:dressly/state/locale_controller.dart';
import 'package:dressly/state/session.dart';
import 'package:dressly/state/theme_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('legacy seed in prefs is dropped, accent defaults to orange', () async {
    SharedPreferences.setMockInitialValues({'theme_seed': 0xFF14B8A6});
    final c = await ThemeController.load();
    expect(c.accent, DsAccent.orange);
    expect(
      (await SharedPreferences.getInstance()).containsKey('theme_seed'),
      isFalse,
    );
  });

  test('accent persists', () async {
    SharedPreferences.setMockInitialValues({});
    await (await ThemeController.load()).setAccent(DsAccent.acid);
    expect((await ThemeController.load()).accent, DsAccent.acid);
  });

  test('dark stays the default mode', () async {
    SharedPreferences.setMockInitialValues({});
    expect((await ThemeController.load()).mode, ThemeMode.dark);
  });

  test('themeFor carries theme F tokens for the chosen accent', () async {
    SharedPreferences.setMockInitialValues({'theme_accent': 'ink'});
    final t = (await ThemeController.load()).themeFor(Brightness.light);
    final tokens = t.extension<DsTokens>()!;
    expect(tokens.colors.bg, const Color(0xFFF1E6D6));
    expect(tokens.colors.accent, DsAccent.ink.base);
  });

  testWidgets('settings screen builds under theme F and lists 5 accents', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final theme = await ThemeController.load();
    final locale = await LocaleController.load();
    final genPrefs = await GenPrefsController.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: Session()),
          ChangeNotifierProvider.value(value: theme),
          ChangeNotifierProvider.value(value: locale),
          ChangeNotifierProvider.value(value: genPrefs),
        ],
        child: MaterialApp(
          theme: theme.themeFor(Brightness.light),
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pump();
    for (final a in DsAccent.values) {
      expect(find.byKey(ValueKey('accent-${a.name}')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('accent-olive')));
    await tester.pump();
    expect(theme.accent, DsAccent.olive);
  });
}
