# Refonte — étape 2 (composants + galerie) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Dressly component library on the theme F tokens, pin each component with golden images (dark + light), and show them all in a gallery that is screenshotted headless on Linux.

**Architecture:** Each component lives in `lib/design/components/` and reads only `context.ds`. None of them does networking: image slots take a `Widget`, so screens pass `AppImage` and tests pass a placeholder. Goldens render with the real bundled fonts. The gallery is a plain screen started instead of the app with `--dart-define=DS_GALLERY=true`.

**Tech Stack:** Flutter (SDK ^3.12), `flutter_test` goldens, `integration_test` + Xvfb for the gallery screenshots.

**Spec:** `docs/superpowers/specs/2026-11-15-refonte-design.md`. Visual reference: section F of `.superpowers/brainstorm/167111-1794697788/content/directions-v2.html`.

## Global Constraints

- `lib/design/components/*` use only `context.ds` tokens. `Color(0x…)` literals are allowed only in `lib/design/theme_f.dart` and `lib/design/garment_tones.dart`.
- No component imports `services/`, `models/` or `state/`. They take plain values and callbacks.
- Every visible string is a parameter; components never call `tr()`.
- Display titles (Anton) are rendered in capitals by the component (`toUpperCase()`), not by callers.
- Touch targets are at least 44×44 logical px.
- Animations use `ds.motion` durations and curves only, and respect `MediaQuery.disableAnimations` (jump to the end state).
- Goldens live in `test/design/goldens/` and are generated on this Linux machine (`flutter test --update-goldens`). Each golden is rendered at 412 px wide, in dark and in light.
- Code and comments in English.

## Review Focus

1. **Long garment names and brands** (40+ characters, a single unbroken word). The card must ellipsize and never overflow. Golden in Task 4.
2. **Text scale 1.6** (accessibility setting). Header, chips, buttons and the tab bar must not overflow. A test pumps each at `textScaler: TextScaler.linear(1.6)` and asserts no overflow exception. Tasks 2 and 3.
3. **An unknown or empty garment colour** (`''`, `'teal'`). The swatch falls back to a neutral tone and does not throw. Test in Task 1.
4. **Animations off** (`disableAnimations: true`). The collage and the card press go straight to the end state. Tests in Tasks 4 and 5.
5. **The light theme.** Every golden exists in light too, and tone pairs keep a silhouette contrast of at least 1.4 on their fill. Test in Task 1.

---

### Task 1: Test harness + garment tones

**Files:**
- Create: `test/support/ds_harness.dart`
- Create: `lib/design/garment_tones.dart`
- Test: `test/design/garment_tones_test.dart`

**Interfaces:**
- Produces, in `test/support/ds_harness.dart`:
  - `Future<void> loadDsFonts()`: loads Anton, Bricolage and PlexMono from `assets/fonts/` via `FontLoader`. Call it in `setUpAll`.
  - `Widget dsFrame(Widget child, {Brightness brightness = Brightness.dark, double width = 412, double textScale = 1})`: a `MaterialApp` with `ThemeF().themeData(brightness, DsAccent.orange)`, `MediaQuery` at the given text scale, and the child centred in a `ColoredBox(ds.colors.bg)` of the given width with 12 px padding.
  - `Future<void> expectDsGolden(WidgetTester t, Widget child, String name, {double height = 200})`: pumps `dsFrame` for both brightnesses at 412×height and runs `matchesGoldenFile('goldens/$name.<dark|light>.png')`.
- Produces, in `lib/design/garment_tones.dart`:
  - `class GarmentTone { final Color fill; final Color shade; final Color onFill; }`
  - `GarmentTone garmentTone(String colorName, Brightness b)`: case-insensitive, accepts the `kColorPalette` names (Black, White, Grey/Gray, Blue, Red, Green, Yellow, Beige, Brown, Orange, Purple, Pink). Anything else returns the neutral tone, which is the F surface colours.
  - Tones are muted to sit in F, not saturated Material colours. Values are left to the implementer, within the contrast rules below.

- [ ] **Step 1: Write the failing tests** `test/design/garment_tones_test.dart`:
  - `every palette colour maps to a non-neutral tone` (for each name of `kColorPalette`, `garmentTone(n, dark) != garmentTone('', dark)`)
  - `unknown and empty names fall back to neutral` (`'teal'`, `''` → equal to the neutral tone, no throw)
  - `case-insensitive` (`'BLACK'` equals `'black'`)
  - `onFill readable on every fill` (`contrast(onFill, fill) >= 4.5`, both brightnesses)
  - `shade visible on fill` (`contrast(shade, fill) >= 1.4`, both brightnesses)
- [ ] **Step 2: Run them.** `flutter test test/design/garment_tones_test.dart`. Expected: FAIL (missing file).
- [ ] **Step 3: Implement** `garment_tones.dart` and `ds_harness.dart`.
- [ ] **Step 4: Run them.** Expected: PASS. Then run `flutter test`: all green.
- [ ] **Step 5: Commit.** `feat(design): tons de vêtement et banc de test des composants`

### Task 2: Primitives — button, chip, segment, badge

**Files:**
- Create: `lib/design/components/ds_button.dart`, `ds_chip.dart`, `ds_badge.dart`
- Modify: `lib/design/ds.dart` (export `components/*.dart`)
- Test: `test/design/primitives_test.dart`

**Interfaces:**
- `enum DsButtonKind { primary, secondary, icon }`
- `DsButton({required String label, required VoidCallback? onPressed, DsButtonKind kind = primary, IconData? icon, bool expand = false, bool loading = false})` plus the named constructor `DsButton.icon({required IconData icon, required String semanticLabel, required VoidCallback? onPressed})`.
  - Pill shape, height 52.
  - `primary`: accent fill with onAccent text in `typo.title`.
  - `secondary`: `surface` fill.
  - `onPressed == null` means disabled (opacity 0.4).
  - `loading` replaces the label with a 20 px progress indicator and ignores taps.
- `DsChip({required String label, required bool selected, required VoidCallback onTap})`: pill, `typo.label`. Selected = `text` fill with `bg` text; otherwise `surface` fill with `textMuted` text.
- `DsSegment<T>({required List<(T, String)> options, required T value, required ValueChanged<T> onChanged})`: a horizontally scrolling row of `DsChip`s, spacing `space.s`.
- `enum DsBadgeTone { neutral, accent }`
- `DsBadge({required String text, DsBadgeTone tone = neutral})`: mono pill in `typo.monoSmall`, uppercase. `neutral` = ink bg with cream text, whatever the brightness. `accent` = accent bg with onAccent text.

- [ ] **Step 1: Write the failing tests:**
  - `DsButton calls onPressed`
  - `disabled DsButton ignores taps`
  - `loading DsButton ignores taps and shows a progress indicator`
  - `DsButton.icon exposes its semantic label` (`find.bySemanticsLabel`)
  - `DsChip calls onTap`
  - `DsSegment reports the tapped value`
  - `primitives do not overflow at text scale 1.6` (pump a column of all four in `dsFrame(textScale: 1.6, width: 360)`, `expect(tester.takeException(), isNull)`)
  - Goldens via `expectDsGolden`: `button_primary`, `button_secondary`, `button_icon`, `chip_states` (selected + unselected), `segment`, `badges`.
- [ ] **Step 2: Run them.** `flutter test test/design/primitives_test.dart`. Expected: FAIL (missing classes).
- [ ] **Step 3: Implement** the three files and the exports.
- [ ] **Step 4: Generate the goldens and run the tests.** `flutter test --update-goldens test/design/primitives_test.dart`, then `flutter test test/design/primitives_test.dart`. Expected: PASS. Open the dark and light `button_primary` goldens and check they match the F maquette (pill, orange, Bricolage).
- [ ] **Step 5: Commit.** `feat(design): boutons, puces, segments et badges`

### Task 3: Layout — header, tab bar, scaffold

**Files:**
- Create: `lib/design/components/ds_header.dart`, `ds_tab_bar.dart`, `ds_scaffold.dart`
- Test: `test/design/layout_test.dart`

**Interfaces:**
- `DsHeader({required String line1, required String line2, List<String> meta = const [], Widget? trailing})`.
  - Two-line display title in `typo.display`, uppercase. `line2` is drawn in `colors.accentText`.
  - `meta` lines are right-aligned in `typo.mono`, uppercase, and stacked.
  - `trailing` (for example a settings icon button) sits above the meta lines.
  - Padding: `gutter` horizontally, `space.l` on top.
- `DsTabItem({required IconData icon, required String label})`
- `DsTabBar({required List<DsTabItem> items, required int index, required ValueChanged<int> onTap})`.
  - A floating pill (`surface` fill, `pillRadius`), centred, 16 px above the bottom safe area.
  - The active item is an accent pill showing icon + label in onAccent. Inactive items show the icon only, in textMuted, with the label as a semantic label.
  - The active pill's width animates with `motion.base` / `motion.standard`.
- `DsScaffold({required Widget body, DsTabBar? tabBar, Widget? header, Widget? floating})`.
  - `bg` background, no AppBar.
  - `header` scrolls with the body (the caller puts it in the scroll view). `DsScaffold` only reserves the bottom inset so content is not hidden behind the floating tab bar: it exposes `static double bottomInset(BuildContext)` = tab bar height + 16 + safe area.

- [ ] **Step 1: Write the failing tests:**
  - `DsHeader uppercases both lines and shows meta`
  - `DsTabBar reports the tapped index`
  - `inactive tabs expose their label to semantics`
  - `header and tab bar do not overflow at text scale 1.6 on a 360 px screen`
  - `DsScaffold.bottomInset clears the tab bar` (bottomInset ≥ the tab bar's rendered height + 16)
  - Goldens: `header` (line1 "Ma", line2 "drip", meta ["87 pièces", "+3 ce mois"]), `tab_bar` (5 items, index 0), `tab_bar_index2`.
- [ ] **Step 2: Run them.** `flutter test test/design/layout_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Generate the goldens and run the tests.** Expected: PASS. Open the `header` dark golden and compare it with the maquette: Anton, the second word in orange, mono meta on the right.
- [ ] **Step 5: Commit.** `feat(design): en-tête géant, barre d'onglets flottante et scaffold`

### Task 4: Content — swatch card, day strip, plan card, layer row

**Files:**
- Create: `lib/design/components/ds_swatch_card.dart`, `ds_day_strip.dart`, `ds_plan_card.dart`, `ds_layer_row.dart`, `ds_pressable.dart`
- Test: `test/design/content_test.dart`

**Interfaces:**
- `DsPressable({required Widget child, required VoidCallback? onTap, VoidCallback? onLongPress})`.
  - Scales to 0.97 on press and springs back with `motion.press` (`SpringSimulation`).
  - With `MediaQuery.disableAnimations` there is no scaling.
  - All tappable cards use it.
- `DsSwatchCard({required Widget image, required String name, String? subtitle, required GarmentTone tone, String? badge, DsBadgeTone badgeTone = neutral, Widget? trailing, required VoidCallback onTap, VoidCallback? onLongPress})`.
  - `tone.fill` background, `cardRadius`, 0.82 aspect ratio.
  - The image is centred in the upper part, at most 62 % of the height.
  - `name` in `typo.bodyStrong` and `subtitle` in `typo.monoSmall`, both in `tone.onFill`, one line each, ellipsized.
  - `badge` at the top left. `trailing` at the top right (favourite toggle).
- `DsDay({required DateTime date, required String weekday, bool hasPlan = false})`
- `DsDayStrip({required List<DsDay> days, required DateTime selected, required ValueChanged<DateTime> onSelect})`.
  - Equal-width cells: `weekday` in mono, day number in `typo.headline`.
  - The selected cell is an accent fill. `hasPlan` shows a 5 px accent dot (onAccent when selected).
- `DsPlanCard({required String title, required String subtitle, required List<Widget> thumbs, GarmentTone? tone, VoidCallback? onTap})`.
  - `title` in `typo.headline` uppercase, `subtitle` in mono, up to 3 thumbs of 40×48 on the right.
  - With `thumbs` empty and `onTap` set, it shows a "+" thumb (empty-day call to action).
  - `tone` null means `surface`.
- `DsLayerRow({required String index, required Widget image, required String name, String? note})`.
  - `index` (for example "L3·EXT") in mono accentText, 54×54 image tile on `surfaceHigh`, `name` in bodyStrong uppercase, `note` in monoSmall.

- [ ] **Step 1: Write the failing tests:**
  - `swatch card ellipsizes a 60-character unbroken name without overflow`
  - `swatch card shows badge and trailing`
  - `DsPressable scales on press` (press, pump 50 ms, `Transform` scale < 1)
  - `DsPressable does not scale with animations disabled`
  - `DsDayStrip reports the tapped date`
  - `plan card with no thumbs shows the add affordance`
  - Goldens: `swatch_grid` (2×2 grid of cards with tones Orange, Green, Beige, Black; placeholder image `Icon(Icons.checkroom, size: 80)` in `tone.shade`), `swatch_long_name`, `day_strip`, `plan_cards` (filled + empty), `layer_rows` (4 rows).
- [ ] **Step 2: Run them.** `flutter test test/design/content_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Generate the goldens and run the tests.** Expected: PASS. Open the `swatch_grid` dark golden and compare it with the F maquette's "Stock" screen.
- [ ] **Step 5: Commit.** `feat(design): cartes vêtement, bande de jours, cartes de plan et couches`

### Task 5: Collage, sheet, states

**Files:**
- Create: `lib/design/components/ds_collage.dart`, `ds_sheet.dart`, `ds_states.dart`
- Test: `test/design/collage_states_test.dart`

**Interfaces:**
- `DsCollage({required List<Widget> pieces, bool play = true})`.
  - Pieces start scattered: each gets a deterministic rotation in ±12° and an offset in ±40 px, seeded by its index.
  - When `play` is true, they settle into a 2-column grid over `motion.slow * 2`, staggered by 60 ms per piece, with `Curves.easeOutBack`.
  - With `disableAnimations` or `play: false` they show the settled grid immediately.
- `Future<T?> showDsSheet<T>(BuildContext context, {required String title, required Widget child})`: modal bottom sheet with `surface` fill, `heroRadius` top corners, a 36×4 handle in hairline, and `title` in `typo.headline` uppercase.
- `DsEmpty({required String title, required String message, String? actionLabel, VoidCallback? onAction})`
- `DsError({required String message, required VoidCallback onRetry, required String retryLabel})`
- `DsSkeleton({required double width, required double height, double? radius})`: `surfaceHigh` block with a shimmer looping over `motion.slow * 4`. Static when animations are disabled.
- `DsSkeleton.swatchGrid({int count = 4})`: placeholders in the shape of a swatch grid.

- [ ] **Step 1: Write the failing tests:**
  - `collage with animations disabled renders settled` (pieces' `Transform` angle == 0)
  - `collage play settles within slow*2 + stagger` (pump the total, angle == 0)
  - `collage mid-animation is rotated` (pump 100 ms, some angle != 0)
  - `showDsSheet shows the uppercased title and returns the popped value`
  - `DsError retry calls onRetry`
  - `DsEmpty action calls onAction`
  - Goldens: `collage_settled`, `sheet`, `empty`, `error`, `skeleton_grid` (with disableAnimations so the golden is stable).
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Generate the goldens and run the tests.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(design): collage, feuille, états vide/erreur/chargement`

### Task 6: Gallery + headless screenshots

**Files:**
- Create: `lib/design/gallery/ds_gallery.dart`
- Modify: `lib/main.dart` (if `const bool.fromEnvironment('DS_GALLERY')`, `runApp(const DsGalleryApp())` and return)
- Create: `integration_test/gallery_test.dart`
- Test: `test/design/gallery_test.dart`

**Interfaces:**
- `DsGalleryApp()`: a `MaterialApp` with its own dark/light and accent toggles, held in local state. Its home is a `DsScaffold` listing every component from Tasks 2–5 in sections. Each section starts with a `DsHeader`-style title. The gallery uses `DsTabBar` itself, with 3 tabs: Primitives, Contenu, États.
- `integration_test/gallery_test.dart`: pumps `DsGalleryApp`, then for each tab and each brightness scrolls through the page and saves screenshots with ImageMagick `import`, as `integration_test/screens_test.dart` does (same `SHOT_DIR` define).

- [ ] **Step 1: Write the failing test** `test/design/gallery_test.dart`:
  - `gallery builds every tab in dark and light without exceptions`
  - `gallery uses no hardcoded style` (already enforced by `design_guard_test`; nothing to add)
- [ ] **Step 2: Run it.** Expected: FAIL (missing `DsGalleryApp`).
- [ ] **Step 3: Implement** the gallery and the `main.dart` switch.
- [ ] **Step 4: Run** `flutter test`. Expected: all green.
- [ ] **Step 5: Take the headless screenshots.**

  `DISPLAY=:99 GDK_BACKEND=x11 DRESSLY_WINDOW_SIZE=412x915 flutter test integration_test/gallery_test.dart -d linux --dart-define=SHOT_DIR=<scratchpad>/gallery`

  Expected: "All tests passed" and one PNG per tab and brightness. Crop them to 412×915 and put them on a single contact sheet to show the user.
- [ ] **Step 6: Commit.** `feat(design): galerie des composants, visible sur Linux sans écran`
