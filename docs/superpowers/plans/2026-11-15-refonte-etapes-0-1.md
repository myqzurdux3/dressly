# Refonte — étapes 0 (mesure) et 1 (fondations) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure today's performance on the real phone, then lay the design-system foundations (tokens, fonts, theme F dark/light, accents, guard test) so every later screen is built on them.

**Architecture:** A profile-mode integration test drives the real app on the phone and writes frame-time summaries; a small Dart tool turns them into a baseline report. The design system lives in `lib/design/`: one `ThemeExtension` (`DsTokens`) bundling colors, type, shape, space and motion, built by a `DsTheme` (theme F is the first one) that also produces a Material `ThemeData`, so unmigrated screens immediately inherit F colors. A ratchet test forbids hardcoded styles outside `lib/design/`, with a shrinking allowlist of legacy files.

**Tech Stack:** Flutter (SDK ^3.12), Provider (kept until step 3), `integration_test`, `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-11-15-refonte-design.md`

## Global Constraints

- Code and comments in English; user-facing copy goes through `lib/l10n/app_text.dart` (FR + EN).
- Public repository: no credentials in code, docs, or commit messages. Perf credentials are passed only via `--dart-define` on the command line.
- All existing tests in `test/` stay green after every task (`flutter test`).
- Fonts are bundled assets (OFL), never fetched at runtime.
- Theme F values: dark bg `#17120F`, surface `#2A221C`, text `#F1E6D6`, olive `#56603D`, default accent orange `#FF7A3D`. Light bg `#F1E6D6`, text `#17120F`.
- Dark mode stays the default `ThemeMode`.
- Nothing outside `lib/design/` may introduce a new `Color(0x`, `Colors.` (except `Colors.transparent`), `TextStyle(`, `BorderRadius.circular(<literal>)` or animation `Duration(`.

## Review Focus

1. **A user who saved an old accent (one of the 10 Material seeds) in SharedPreferences.** The app must start on the default orange accent, not crash or show teal. Test in Task 4.
2. **The light theme.** Every token pair used for text must stay readable on cream. Contrast tests in Task 3 cover both brightnesses and every accent.
3. **Legacy screens rendered with the new `ThemeData`.** They must still build: no null extension lookup, no missing font. Smoke test in Task 4.
4. **Perf run without credentials or with wrong ones.** The test must fail fast with a clear message, not hang on the login screen. Assertion in Task 1.
5. **A legacy file that gets cleaned but stays on the allowlist.** The ratchet must force its removal, otherwise the allowlist never shrinks. Test in Task 5.

---

### Task 1: Perf harness (integration test + report tool)

**Files:**
- Modify: `pubspec.yaml` (dev_dependencies: `integration_test: {sdk: flutter}`)
- Modify: `lib/main.dart` — extract `Future<Widget> bootstrap()`
- Create: `integration_test/perf_test.dart`
- Create: `test_driver/perf_driver.dart`
- Create: `tool/perf_report.dart`
- Test: `test/perf_report_test.dart`

**Interfaces:**
- Produces: `Future<Widget> bootstrap()` in `lib/main.dart`. It does everything `main()` does today except `runApp`, and returns the `MultiProvider(child: Dressly())` tree. `main()` becomes `runApp(await bootstrap())`.
- Produces: `String renderPerfReport(Map<String, Map<String, dynamic>> summaries, Map<String, int> apiMs)` in `tool/perf_report.dart`. It returns a Markdown table.

- [ ] **Step 1: Write the failing test** `test/perf_report_test.dart`

```dart
test('renders one row per traced action with frame stats', () {
  final md = renderPerfReport({
    'wardrobe_scroll': {
      'average_frame_build_time_millis': 4.2,
      '90th_percentile_frame_build_time_millis': 7.9,
      'average_frame_rasterizer_time_millis': 6.1,
      '90th_percentile_frame_rasterizer_time_millis': 11.3,
      'missed_frame_build_budget_count': 3,
      'missed_frame_rasterizer_budget_count': 5,
      'frame_count': 240,
    },
  }, {'clothes.list': 412});
  expect(md, contains('| wardrobe_scroll | 240 | 4.2 | 7.9 | 6.1 | 11.3 | 3 | 5 |'));
  expect(md, contains('| clothes.list | 412 |'));
});
```

- [ ] **Step 2: Run it.** `flutter test test/perf_report_test.dart`. Expected: FAIL (`renderPerfReport` undefined).
- [ ] **Step 3: Implement `renderPerfReport`.** Two tables. The first has the header `| action | frames | build avg | build p90 | raster avg | raster p90 | build missed | raster missed |`, with numbers printed as-is. The second has the header `| api call | ms |`. Add a `main(List<String> args)` that reads `build/perf/*.timeline_summary.json` (key = file name without suffix) plus `build/perf/api_ms.json` and prints the report.
- [ ] **Step 4: Run it.** Expected: PASS.
- [ ] **Step 5: Extract `bootstrap()` in `lib/main.dart`**, then run `flutter test`. Expected: all green.
- [ ] **Step 6: Write `integration_test/perf_test.dart`.**
  - Read `const String.fromEnvironment('PERF_EMAIL')` and `PERF_PASSWORD`. If either is empty, `fail('Pass --dart-define=PERF_EMAIL=… --dart-define=PERF_PASSWORD=…')` before anything else.
  - Call `AuthService().login(...)`, which stores the token, then `tester.pumpWidget(await bootstrap())` and `pumpAndSettle`. The restore path then lands on `HomeShell`. If `find.byType(HomeShell)` is absent after 15 s of pumping, fail with "login did not reach HomeShell".
  - Time `ClothesService(api).list(limit: 30)` with a `Stopwatch` into `apiMs['clothes.list']`.
  - Use `binding.traceAction(reportKey: ...)` for each action:
    - `wardrobe_scroll`: three `tester.fling(find.byType(CustomScrollView).first, Offset(0, -1200), 3000)` followed by `pumpAndSettle`, then three flings back up.
    - `cloth_detail_open`: tap `find.byType(ClothCard).first`, `pumpAndSettle`, then `pageBack()` and `pumpAndSettle`.
    - `tab_switch`: tap each `find.byType(NavigationDestination).at(i)` for i = 1..4 and back to 0, with `pumpAndSettle` each time.
  - Put `apiMs` into `binding.reportData!['api_ms']`.
- [ ] **Step 7: Write `test_driver/perf_driver.dart`.** Use `integrationDriver(responseDataCallback: ...)`. For each key except `api_ms`, call `TimelineSummary.summarize(Timeline.fromJson(data[key]))` and `writeTimelineToFile(key, destinationDirectory: 'build/perf', pretty: true)`. Write `api_ms` to `build/perf/api_ms.json`.
- [ ] **Step 8: Verify on the device.**

  `flutter drive --profile --no-dds --driver=test_driver/perf_driver.dart --target=integration_test/perf_test.dart -d <device> --dart-define=PERF_EMAIL=<user> --dart-define=PERF_PASSWORD=<pass>`

  Expected: "All tests passed", and `build/perf/` contains three `*.timeline_summary.json` files plus `api_ms.json`. The user types the credentials themselves (`! <command>`).
- [ ] **Step 9: Commit.** `feat(perf): banc de mesure en mode profile sur l'appareil`

### Task 2: Baseline report

**Files:**
- Create: `docs/perf/2026-11-15-baseline.md`

- [ ] **Step 1: Cold start.** On the device: `flutter run --profile --trace-startup -d <device>`. Expected: `build/start_up_info.json` contains `timeToFirstFrameMicros`. Run it 3 times and keep the median.
- [ ] **Step 2: Perf run.** Run Task 1 step 8 three times. Keep the median run of `wardrobe_scroll` by raster p90.
- [ ] **Step 3: Write the report.** `dart run tool/perf_report.dart > /tmp/r.md`, then write `docs/perf/2026-11-15-baseline.md` containing: device model (`adb shell getprop ro.product.model`), Flutter version, startup median, the report tables, and a "Lecture" section naming the worst action and whether build or raster dominates. No conclusions beyond what the numbers show.
- [ ] **Step 4: Commit.** `docs(perf): mesure de référence avant refonte`

### Task 3: Design tokens + theme F

**Files:**
- Create: `lib/design/tokens.dart` — `DsColors`, `DsType`, `DsShape`, `DsSpace`, `DsMotion`, `DsTokens`
- Create: `lib/design/accent.dart` — `DsAccent`
- Create: `lib/design/theme_f.dart` — theme F
- Create: `lib/design/ds.dart` — barrel export + `BuildContext` extension
- Create: `assets/fonts/Anton-Regular.ttf`, `BricolageGrotesque[opsz,wdth,wght].ttf`, `IBMPlexMono-Regular.ttf`, `IBMPlexMono-Medium.ttf`, `IBMPlexMono-SemiBold.ttf`, plus their OFL texts appended to `assets/fonts/OFL.txt`
- Modify: `pubspec.yaml` — font families `Anton`, `Bricolage`, `PlexMono`
- Test: `test/design/tokens_test.dart`

**Interfaces:**
- Produces:
  - `enum DsAccent { orange, olive, brick, ink, acid }`, with `Color base` and `Color deep` fields:
    - orange `#FF7A3D` / `#B4471A`
    - olive `#A3AE62` / `#56603D`
    - brick `#E0583A` / `#9E3720`
    - ink `#6F8BFF` / `#2D45B8`
    - acid `#D7FF3A` / `#5E7300`

    `static DsAccent fromName(String? n)` returns `orange` for null or unknown names.
  - `class DsColors` (immutable, `lerp`) with fields: `bg`, `surface`, `surfaceHigh`, `text`, `textMuted`, `hairline`, `accent`, `onAccent`, `accentText`, `olive`, `danger`.
  - `class DsType` with `TextStyle` fields `display`, `headline`, `title`, `body`, `bodyStrong`, `label`, `mono`, `monoSmall`, and `static DsType of(DsColors c)`.
  - `class DsShape` with `double` fields `small`, `card`, `hero`, `pill` and getters `BorderRadius cardRadius`, `heroRadius`, `pillRadius`.
  - `class DsSpace` with `double` fields `xs`, `s`, `m`, `l`, `xl`, `xxl`, `gutter`.
  - `class DsMotion` with `Duration` fields `fast`, `base`, `slow`, `Curve standard`, and `SpringDescription press`.
  - `class DsTokens extends ThemeExtension<DsTokens>` with fields `colors`, `type`, `shape`, `space`, `motion`. In `lerp`, colors and type interpolate; the other fields snap at t = 0.5.
  - `abstract class DsTheme { String get id; DsTokens tokens(Brightness b, DsAccent a); ThemeData themeData(Brightness b, DsAccent a); }`
  - `class ThemeF implements DsTheme`, with `id == 'f'`.
  - `extension DsContext on BuildContext { DsTokens get ds; }`. It throws a `StateError('DsTokens missing from Theme')` when the extension is absent.
- Values for F:
  - **Dark:** bg `#17120F`, surface `#2A221C`, surfaceHigh `#362C24`, text `#F1E6D6`, textMuted `#9A8877`, hairline `#3A3029`, olive `#56603D`, danger `#FF5A4E`. accent = `base`, accentText = `base`.
  - **Light:** bg `#F1E6D6`, surface `#E6D8C4`, surfaceHigh `#DCCBB3`, text `#17120F`, textMuted `#6E5B4A`, hairline `#D3C0A6`, olive `#56603D`, danger `#B3261E`. accent = `base`, accentText = `deep`.
  - `onAccent`: `#17120F` if the accent's luminance is > 0.25, otherwise `#F1E6D6`.
  - **Type:** display = Anton 56/0.85 height, uppercase by convention; headline = Anton 26; title = Bricolage w700 18; body = Bricolage w400 15; bodyStrong = w600 15; label = Bricolage w600 12; mono = PlexMono w500 11 letterSpacing 0.5; monoSmall = PlexMono 9. Use `FontVariation.weight` for Bricolage.
  - **Shape:** small 10, card 20, hero 26, pill 999.
  - **Space:** xs 4, s 8, m 12, l 16, xl 24, xxl 32, gutter 12.
  - **Motion:** fast 150 ms, base 220 ms, slow 320 ms, standard `Curves.easeOutCubic`, press = `SpringDescription(mass: 1, stiffness: 380, damping: 26)`.

- [ ] **Step 1: Write the failing tests** `test/design/tokens_test.dart`. Reuse the WCAG `_contrast` helper from `test/light_theme_test.dart` by moving it to `test/support/contrast.dart`.

```dart
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
});
testWidgets('context.ds reads the extension', (t) async {
  late DsTokens got;
  await t.pumpWidget(MaterialApp(
    theme: const ThemeF().themeData(Brightness.dark, DsAccent.orange),
    home: Builder(builder: (c) { got = c.ds; return const SizedBox(); }),
  ));
  expect(got.colors.bg, const Color(0xFF17120F));
});
test('lerp interpolates colors', () {
  final d = const ThemeF().tokens(Brightness.dark, DsAccent.orange);
  final l = const ThemeF().tokens(Brightness.light, DsAccent.orange);
  expect(d.lerp(l, 0.5).colors.bg, Color.lerp(d.colors.bg, l.colors.bg, 0.5));
});
```

- [ ] **Step 2: Run it.** `flutter test test/design/tokens_test.dart`. Expected: FAIL (missing library).
- [ ] **Step 3: Download the fonts.** Get the TTFs from `https://github.com/google/fonts/raw/main/ofl/{anton,bricolagegrotesque,ibmplexmono}/…` into `assets/fonts/`, then declare the three families in `pubspec.yaml`.
- [ ] **Step 4: Implement** `tokens.dart`, `accent.dart`, `theme_f.dart` and `ds.dart` with the values above. `themeData` builds a `ColorScheme` from the tokens: primary = accent, onPrimary = onAccent, surface = bg, onSurface = text, onSurfaceVariant = textMuted, outline = textMuted, outlineVariant = hairline, surfaceContainerHighest = surfaceHigh, secondary = olive, error = danger. It sets `scaffoldBackgroundColor = bg`, `fontFamily = 'Bricolage'`, `extensions: [tokens]`, and `navigationBarTheme` with bg = surface, indicator = accent, `labelTextStyle` from `type.label`.
- [ ] **Step 5: Run the tests.** Expected: PASS. If a contrast test fails, adjust only the failing token (muted/deep variants), record the new value in this plan, and re-run.
- [ ] **Step 6: Run `flutter test`.** Expected: all green, `light_theme_test.dart` included.
- [ ] **Step 7: Commit.** `feat(design): jetons du système de design et thème F`

### Task 4: Wire theme F into the app

**Files:**
- Modify: `lib/state/theme_controller.dart` — replace the seed with `DsAccent`
- Modify: `lib/app.dart:26-33`
- Modify: `lib/screens/settings/settings_screen.dart:30-76` — the accent picker iterates `DsAccent.values` and shows `accent.base`
- Modify: `lib/l10n/app_text.dart` — keys `accent.orange|olive|brick|ink|acid` (FR: Orange, Olive, Brique, Encre, Acide; EN: Orange, Olive, Brick, Ink, Acid)
- Test: `test/design/theme_wiring_test.dart`

**Interfaces:**
- Consumes: `ThemeF`, `DsAccent`, `DsTheme.themeData` (Task 3).
- Produces: `ThemeController` with `DsAccent get accent`, `Future<void> setAccent(DsAccent a)`, `ThemeData themeFor(Brightness b)` (delegates to `ThemeF`), and `mode` unchanged. The SharedPreferences key is `theme_accent` (the name string). The old key `theme_seed` is ignored and removed on the first `load()`.

- [ ] **Step 1: Write the failing tests.**

```dart
test('legacy seed in prefs is dropped, accent defaults to orange', () async {
  SharedPreferences.setMockInitialValues({'theme_seed': 0xFF14B8A6});
  final c = await ThemeController.load();
  expect(c.accent, DsAccent.orange);
  expect((await SharedPreferences.getInstance()).containsKey('theme_seed'), isFalse);
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
testWidgets('settings screen builds under theme F and lists 5 accents', ...);
```

  The widget test pumps `SettingsScreen` inside the providers, using `themeFor(Brightness.light)`, and expects 5 accent swatches (`find.byKey(ValueKey('accent-$name'))`). It must follow the harness setup recorded in the widget-testing memory.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement** the controller, `app.dart` and the settings changes. Delete `presets`, `defaultSeed` and `setSeed`.
- [ ] **Step 4: Run `flutter test`.** Expected: all green.
- [ ] **Step 5: Check on the device.** `flutter run -d <device>`: the app opens in F dark (chocolate background, orange nav indicator), switching to light gives cream, and changing the accent applies immediately. Take a screenshot with `adb exec-out screencap -p > /tmp/f-dark.png`.
- [ ] **Step 6: Commit.** `feat(theme): l'app passe au thème F et aux accents Dressly`

### Task 5: Ratchet guard against hardcoded styles

**Files:**
- Create: `test/design_guard_test.dart`
- Create: `test/design_guard_legacy.txt` — one repo-relative path per line, sorted

**Interfaces:**
- Consumes: nothing.
- Produces: the rule every later step obeys. A migrated file must be removed from `design_guard_legacy.txt`.

- [ ] **Step 1: Write the test.** It scans `lib/**/*.dart` except `lib/design/**` with these patterns:
  - `Color\(0x`
  - `Colors\.(?!transparent\b)`
  - `TextStyle\(`
  - `BorderRadius\.circular\(\s*\d`
  - `Duration\(\s*milliseconds:` (only on lines that also contain `animat`, `Animat`, `transition`, `curve` or `duration:`).

  Two assertions:
  - (a) every offending file is in the legacy list, and the failure message lists `path:line`;
  - (b) every file in the legacy list still offends ("<path> is clean, remove it from design_guard_legacy.txt").
- [ ] **Step 2: Generate the initial legacy list** from the current offenders using a throwaway script. Then run `flutter test test/design_guard_test.dart`. Expected: PASS.
- [ ] **Step 3: Prove the ratchet.**
  - Add `final _x = Colors.red;` to `lib/design/ds.dart`. Expected: still PASS, because design files are exempt.
  - Add it to `lib/state/session.dart` instead. Expected: FAIL naming `lib/state/session.dart:<line>`.
  - Add a file that is already clean (for example `lib/state/session.dart`) to the legacy list. Expected: FAIL with "is clean".
  - Revert all of it.
- [ ] **Step 4: Run `flutter test`.** Expected: all green.
- [ ] **Step 5: Commit.** `test(design): garde-fou contre les styles codés en dur (liste legacy à réduire)`
