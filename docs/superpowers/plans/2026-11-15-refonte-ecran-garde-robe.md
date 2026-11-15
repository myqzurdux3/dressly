# Refonte — écran Garde-robe (+ Riverpod) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the wardrobe tab on the design system (theme F) with its state in Riverpod, keep every current behaviour, and swap the app's bottom navigation for `DsTabBar`.

**Architecture:**
- `flutter_riverpod` is added next to Provider. A `ProviderScope` at the root, plus a nested one in `HomeShell` that overrides `apiClientProvider` with the logged-in session's token, so everything below the shell gets authenticated services.
- The wardrobe's filter is a `Notifier`. Its paged list is a provider-owned `PagedList<Cloth>` that refreshes whenever the filter changes.
- The screen is a `ConsumerStatefulWidget` built only from `Ds*` components and a `WardrobeCard` that adapts a `Cloth` to `DsSwatchCard`.

**Tech Stack:** Flutter, flutter_riverpod 3.x, existing `PagedList` / `PagedGrid`, `PinnedHttp.setClientForTesting` + `MockClient` for widget tests.

**Spec:** `docs/superpowers/specs/2026-11-15-refonte-design.md`

## Global Constraints

- New and migrated files contain no hardcoded style; `lib/screens/home/collection_screen.dart` and `lib/widgets/cloth_card.dart` leave `test/design_guard_legacy.txt` once deleted.
- Sober copy: no slang, no skate. Tab labels keep the existing l10n keys (`nav.wardrobe`, `nav.create`, `nav.agenda`, `nav.saved`, `nav.profile`). Every new string goes in `app_text.dart`, EN and FR.
- Behaviour parity with `collection_screen.dart`:
  - 300 ms search debounce;
  - favourites filter;
  - filter sheet with brand and tag autocomplete, loaded once;
  - favourite toggle that patches one card, with a snackbar on failure and the card removed when un-favourited under the favourites filter;
  - long-press to delete, with confirmation;
  - after returning from the detail screen, re-read that one garment and drop its card only on a 404;
  - count shown as "N+" while more pages remain;
  - a snackbar on load failure;
  - pull to refresh;
  - the "add" button opening `AddClothScreen`, then a refresh.
- Card images use the server thumbnail (`ClothImage.thumbnailUrl`) through `AppImage.path` with `memWidth: 400`.
- Card keys are `ValueKey(cloth.id)` (otherwise re-sorting shows a stale back side).

## Review Focus

1. **Logging out and back in as another account.** The nested `ProviderScope` must rebuild with the new token, never reuse the old client. Test in Task 1.
2. **Typing fast in search.** Only one request per 300 ms pause, carrying the last text. Test in Task 3.
3. **A garment with no colours, or none marked `full`.** The card falls back to the first colour, then to neutral. Test in Task 2.
4. **A server error on the first page.** The screen shows `DsError` with a retry, not an empty wardrobe. Test in Task 3.
5. **Legacy tabs under the new tab bar.** Their content must not hide behind it: the shell does not use `extendBody`. Covered by the Linux screen tour in Task 4.

---

### Task 1: Riverpod plumbing

**Files:**
- Modify: `pubspec.yaml` (`flutter_riverpod: ^3.0.0`)
- Create: `lib/state/providers.dart`
- Modify: `lib/main.dart` (wrap the tree in `ProviderScope`), `lib/screens/home/home_shell.dart` (nested `ProviderScope` overriding `apiClientProvider` from `context.watch<Session>().token`, keyed by the token)
- Test: `test/state/providers_test.dart`

**Interfaces:**
- `final apiClientProvider = Provider<ApiClient>((ref) => throw UnimplementedError('override in HomeShell'));`
- `final clothesServiceProvider = Provider<ClothesService>((ref) => ClothesService(ref.watch(apiClientProvider)));`

- [ ] **Step 1: Write the failing tests:**
  - `clothesServiceProvider uses the overridden api client`: a `ProviderContainer` overriding `apiClientProvider` with `ApiClient(token: 't1')`; a `MockClient` captures the `Authorization` header of `container.read(clothesServiceProvider).list(limit: 1)` and it is `Bearer t1`.
  - `reading apiClientProvider without override throws`
  - `HomeShell rebuilds services when the session token changes`: pump `HomeShell` under `Session` with token `a`, change it to `b`, and verify that a request from the wardrobe tab carries `Bearer b`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them, then the whole suite.** Expected: PASS and all green.
- [ ] **Step 5: Commit.** `feat(state): Riverpod à côté de Provider, services authentifiés sous HomeShell`

### Task 2: WardrobeCard

**Files:**
- Create: `lib/screens/wardrobe/wardrobe_card.dart`
- Test: `test/wardrobe/wardrobe_card_test.dart`

**Interfaces:**
- `WardrobeCard({required Cloth cloth, required VoidCallback onTap, VoidCallback? onLongPress, VoidCallback? onToggleFavorite, ImageBuilder? imageBuilder})`
- `typedef ImageBuilder = Widget Function(String path, double memWidth);` By default it calls `AppImage.path(path, cacheKey: path, memWidth: memWidth)`. Tests pass a placeholder.
- `String swatchColorOf(Cloth c)`: the first colour with dominance `full`, otherwise the first colour, otherwise `''`.
- The card renders a `DsSwatchCard`:
  - `name` = `cloth.name`;
  - `subtitle` = brand, plus ` · N/5` when rated (PlexMono has no ★);
  - `tone` = `garmentTone(swatchColorOf(c), brightness)`;
  - `badge` = `tr('card.review')` when an image is pending review (`bgAccepted == 'pending' || enhanceStatus == 'ready'`);
  - `trailing` = a column with the favourite heart (44×44, semantic label from `wardrobe.favoriteTooltip`) and, when both sides exist, a 32×40 thumbnail of the other side that swaps front and back.

- [ ] **Step 1: Write the failing tests:**
  - `swatchColorOf prefers full, then first, then empty`
  - `review badge shows when an image is pending`
  - `subtitle shows brand and rating`
  - `heart calls onToggleFavorite`
  - `tapping the back thumbnail swaps the main image path`: the `imageBuilder` records paths, and the front path is followed by the back path.
  - Golden `wardrobe_card` (dark and light) using `expectDsGolden` with a placeholder image.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Generate the goldens and run the tests.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(garde-robe): carte vêtement sur DsSwatchCard`

### Task 3: Wardrobe state + screen

**Files:**
- Create: `lib/design/components/ds_search_field.dart`
- Create: `lib/screens/wardrobe/wardrobe_state.dart`
- Create: `lib/screens/wardrobe/wardrobe_screen.dart`
- Test: `test/wardrobe/wardrobe_screen_test.dart`, `test/design/search_field_test.dart`

**Interfaces:**
- `DsSearchField({required TextEditingController controller, required String hint, ValueChanged<String>? onChanged, ValueChanged<String>? onSubmitted})`: a pill on the `surface` colour, 48 px tall, with a search icon and a clear button when there is text. The clear button empties the field and calls `onChanged('')`.
- `class WardrobeFilter extends Notifier<ClothFilter>` with initial state `ClothFilter(sort: 'newest')`, and the methods `setSearch(String)`, `toggleFavorites()`, `setCategory(String?)`, `replace(ClothFilter)`.
- `final wardrobeFilterProvider = NotifierProvider<WardrobeFilter, ClothFilter>(WardrobeFilter.new);`
- `final wardrobeListProvider = Provider.autoDispose<PagedList<Cloth>>(...)`:
  - it creates the `PagedList` using `clothesServiceProvider` and reads the filter at call time;
  - it calls `refresh()` on creation and on each `wardrobeFilterProvider` change (`ref.listen`);
  - it disposes the list in `ref.onDispose`.
- `WardrobeScreen` (`ConsumerStatefulWidget`). Its layout is a `RefreshIndicator` around a `PagedGrid<Cloth>`, whose `header` holds:
  - `DsHeader(line1: tr('wardrobe.title1'), line2: tr('wardrobe.title2'), meta: [count line], trailing: settings DsButton.icon)`, with FR « Garde- » / « robe » and EN « Ward- » / « robe »;
  - a `DsSearchField`;
  - a `DsSegment<String?>` with Tout, Favoris, then each `kCategoryOptions` entry through `categoryLabel`. Favoris maps to `toggleFavorites`, the categories to `setCategory`;
  - a "Filtres" `DsChip` that opens the existing `FilterSheet` through `showModalBottomSheet`; its result goes to `replace`.

  The grid uses 2 columns, `childAspectRatio: DsSwatchCard.aspectRatio`, a spacing of `space.s` and a bottom padding of `DsScaffold.bottomInset`. Empty pages show `DsEmpty`. A first page that failed shows `DsError` with a retry. A first load shows `DsSkeleton.swatchGrid()`. The floating action is a `DsButton(icon: Icons.add, label: tr('wardrobe.addClothes'))`.

- [ ] **Step 1: Write the failing tests.** Use `PinnedHttp.setClientForTesting(MockClient)` with a fixture of 3 garments. Follow the widget-test traps memory: no `pumpAndSettle` while a spinner is shown.
  - `shows one card per garment and the count`
  - `typing in search sends one request with the last text after 300 ms`
  - `Favoris chip requests favorite=true`
  - `category chip requests category=hoodie`
  - `first page error shows DsError and retry reloads`
  - `empty wardrobe shows DsEmpty`
  - `favourite toggle failure shows a snackbar and keeps the card state`
  - `long press then confirm deletes and removes the card`
  - `DsSearchField clear button empties and reports ''`
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.** Port the detail-return, 404 and autocomplete logic from `collection_screen.dart` unchanged in behaviour.
- [ ] **Step 4: Run the tests and `flutter test`.** Expected: PASS, all green.
- [ ] **Step 5: Commit.** `feat(garde-robe): écran refait sur le système de design, état en Riverpod`

### Task 4: Shell switch + cleanup + verification

**Files:**
- Modify: `lib/screens/home/home_shell.dart`:
  - the first page becomes `WardrobeScreen`;
  - `NavigationBar` is replaced by a `DsTabBar`, centred in `bottomNavigationBar` with a 16 px bottom margin and no `extendBody`, using the existing nav labels and icons.
- Delete: `lib/screens/home/collection_screen.dart`, `lib/widgets/cloth_card.dart` (once nothing imports it; `signup_screen.dart` and `light_theme_test.dart` reference `ClothCard`: move them to `WardrobeCard` or drop the obsolete assertions).
- Modify: `test/design_guard_legacy.txt`, `integration_test/screens_test.dart` and `integration_test/perf_test.dart` (they find `ClothCard` and `NavigationDestination`; switch to `WardrobeCard` and `DsTabBar` semantics labels).

- [ ] **Step 1: Update the integration tests' finders.** Run `flutter test`. Expected: all green, and the guard passes with the two files out of the legacy list.
- [ ] **Step 2: Run the Linux screen tour** (`integration_test/screens_test.dart` under Xvfb at 412×915). Expected: PASS, and every tab's content is visible above the tab bar.
- [ ] **Step 3: Run the Linux perf run three times** and add a "Garde-robe refaite" section to `docs/perf/2026-11-15-baseline.md` comparing `wardrobe_scroll` with the baseline.
- [ ] **Step 4: Commit.** `feat(garde-robe): l'app ouvre sur la nouvelle garde-robe et la barre d'onglets Dressly`
