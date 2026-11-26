// Visual tour of the app on the Linux desktop target: logs in, visits each
// tab and the first garment, and saves a screenshot of each.
//
//   DISPLAY=:99 DRESSLY_WINDOW_SIZE=412x915 flutter test \
//     integration_test/screens_test.dart -d linux \
//     --dart-define=PERF_EMAIL=... --dart-define=PERF_PASSWORD=... \
//     --dart-define=SHOT_DIR=/abs/path \
//     [--dart-define=API_BASE_URL=http://127.0.0.1:8000] [--dart-define=LANG=en]
//
// Screenshots are taken with ImageMagick `import` on the X display, so they
// show exactly what was rendered. Credentials only come from the command line.
import 'dart:io';

import 'package:dressly/main.dart';
import 'package:dressly/screens/auth/login_screen.dart';
import 'package:dressly/screens/home/home_shell.dart';
import 'package:dressly/services/auth_service.dart';
import 'package:dressly/design/ds.dart';
import 'package:dressly/screens/wardrobe/wardrobe_card.dart';
import 'package:dressly/widgets/outfit_history_card.dart';
import 'package:flutter/material.dart';
import 'package:dressly/widgets/model_chip.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _email = String.fromEnvironment('PERF_EMAIL');
const _password = String.fromEnvironment('PERF_PASSWORD');
const _shotDir = String.fromEnvironment('SHOT_DIR', defaultValue: '/tmp');
// The app's main language; pass LANG=en for the English strings.
const _lang = String.fromEnvironment('LANG', defaultValue: 'fr');

/// Pumps frames for [d] without waiting for animations to stop (spinners
/// never settle).
Future<void> _settle(
  WidgetTester t, [
  Duration d = const Duration(seconds: 3),
]) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _shot(WidgetTester t, String name) async {
  await _settle(t, const Duration(milliseconds: 600));
  final r = await Process.run('import', [
    '-window',
    'root',
    '$_shotDir/$name.png',
  ]);
  if (r.exitCode != 0) fail('screenshot $name failed: ${r.stderr}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('screens tour', (tester) async {
    if (_email.isEmpty || _password.isEmpty) {
      fail('Pass --dart-define=PERF_EMAIL=... --dart-define=PERF_PASSWORD=...');
    }
    // Signed out, in the tour's language: the real app shows its own sign-in
    // page with the user's theme. The tour then signs in through the API.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_language', _lang);
    await const AuthService().clearToken();
    await tester.pumpWidget(await bootstrap());
    await _settle(tester);
    expect(find.byType(LoginScreen), findsOneWidget);
    await _shot(tester, '00_login');
    await const AuthService().login(_email, _password);
    // Unmount first: a ProviderScope keeps the overrides it was built with,
    // so the signed-out session from the first bootstrap would stay.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(await bootstrap());
    await _settle(tester, const Duration(seconds: 6));
    expect(find.byType(HomeShell), findsOneWidget);

    await _shot(tester, '01_wardrobe');
    Finder tab(int i) => find.descendant(
      of: find.byType(DsTabBar),
      matching: find.byIcon(HomeShell.tabIcons[i]),
    );
    const names = [
      '02_create',
      '02b_stylist',
      '03_agenda',
      '04_saved',
      '05_profile',
    ];
    for (var i = 1; i <= 5; i++) {
      await tester.tap(tab(i));
      await _settle(tester);
      await _shot(tester, names[i - 1]);
    }
    await tester.tap(tab(0));
    await _settle(tester);
    await tester.tap(find.byType(WardrobeCard).first);
    await _settle(tester, const Duration(seconds: 4));
    await _shot(tester, '06_cloth_detail');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -700));
    await _settle(tester);
    await _shot(tester, '07_cloth_detail_photos');

    // Crop & rotate, from the photo panel.
    await tester.tap(find.byIcon(Icons.crop_rotate).first);
    await _settle(tester, const Duration(seconds: 3));
    await _shot(tester, '08_photo_edit');
    await tester.binding.handlePopRoute();
    await _settle(tester);
    await tester.binding.handlePopRoute(); // back to the wardrobe
    await _settle(tester);

    // The add form, top then bottom.
    await tester.tap(find.byIcon(Icons.add).first);
    await _settle(tester);
    await _shot(tester, '09_add_form');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
    await _settle(tester);
    await _shot(tester, '10_add_form_bottom');
    await tester.binding.handlePopRoute();
    await _settle(tester);

    // An outfit's result, from the Create tab's history.
    await tester.tap(tab(1));
    await _settle(tester);
    // Lazy list: the history is not built until scrolled to, so no `.first`
    // until it is.
    final cards = find.byType(OutfitHistoryCard);
    for (var i = 0; i < 20 && cards.evaluate().isEmpty; i++) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
      await tester.pump(const Duration(milliseconds: 200));
    }
    // An empty history (fresh account) has no result to open: shoot the
    // empty history instead.
    if (cards.evaluate().isEmpty) {
      await _settle(tester);
      await _shot(tester, '11_history_empty');
    } else {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
      await _settle(tester);
      await tester.tap(cards.first);
      await _settle(tester, const Duration(seconds: 3));
      await _shot(tester, '11_result');
      // A manual outfit opens in the editor, which does not scroll.
      if (find.byType(Scrollable).evaluate().isNotEmpty) {
        // The last Scrollable can be a horizontal chip row; scroll the page.
        final vertical = find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        );
        await tester.drag(vertical.last, const Offset(0, -700));
        await _settle(tester);
        await _shot(tester, '12_result_bottom');
      }
      await tester.binding.handlePopRoute(); // close the result
      await _settle(tester);
    }

    // Automatic pick: the sheet, then its preview. Nothing is rendered: the
    // preview only asks the server which clothes it would choose.
    final auto = find.byIcon(Icons.casino_outlined);
    for (var i = 0; i < 20 && auto.hitTestable().evaluate().isEmpty; i++) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 400));
      await tester.pump(const Duration(milliseconds: 200));
    }
    await _settle(tester);
    await tester.tap(auto);
    await _settle(tester, const Duration(seconds: 2));
    await _shot(tester, '13_algo_sheet');
    await tester.ensureVisible(find.byIcon(Icons.auto_awesome).last);
    await _settle(tester);
    await tester.tap(find.byIcon(Icons.auto_awesome).last);
    await _settle(tester, const Duration(seconds: 4));
    await _shot(tester, '14_algo_preview');
    await tester.tap(find.byIcon(Icons.close).last);
    await _settle(tester);

    // Manual builder: switch the Create tab to Manual, open a new canvas.
    final seg = find.byType(DsSegment<String>).first;
    for (var i = 0; i < 20 && seg.hitTestable().evaluate().isEmpty; i++) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 400));
      await tester.pump(const Duration(milliseconds: 200));
    }
    await _settle(tester);
    await tester.tap(
      find.descendant(of: seg, matching: find.byType(DsChip)).at(1),
    );
    await _settle(tester);
    await tester.tap(find.byIcon(Icons.brush));
    await _settle(tester, const Duration(seconds: 3));
    await _shot(tester, '15_builder');
    await tester.binding.handlePopRoute();
    await _settle(tester);

    // The week planner and its options, from the Agenda tab.
    await tester.tap(tab(3));
    await _settle(tester);
    await tester.tap(find.byIcon(Icons.auto_awesome_motion_outlined).first);
    await _settle(tester, const Duration(seconds: 5));
    await _shot(tester, '16_week');
    await tester.tap(find.byIcon(Icons.tune).first);
    await _settle(tester, const Duration(seconds: 3));
    await _shot(tester, '17_week_options');
    await tester.binding.handlePopRoute();
    await _settle(tester);
    await tester.binding.handlePopRoute();
    await _settle(tester);

    // Settings and its sub-pages, from the Profile tab.
    await tester.tap(tab(5));
    await _settle(tester);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await _settle(tester);
    await _shot(tester, '18_settings');
    var n = 19;
    for (final icon in const [
      Icons.wb_sunny_outlined,
      Icons.receipt_long_outlined,
      Icons.flag_outlined,
      Icons.lock_outline,
    ]) {
      // Costs and Reports are admin-only: absent for a regular account.
      if (find.byIcon(icon).evaluate().isEmpty) continue;
      await tester.ensureVisible(find.byIcon(icon).first);
      await _settle(tester);
      await tester.tap(find.byIcon(icon).first);
      await _settle(tester, const Duration(seconds: 3));
      await _shot(tester, '${n++}_settings_sub');
      await tester.binding.handlePopRoute();
      await _settle(tester);
    }
    await tester.binding.handlePopRoute();
    await _settle(tester);

    // Models: list, one model, the add form — from the Create tab.
    await tester.tap(tab(1));
    await _settle(tester);
    // The builder step left this tab on Manual: back to AI, where the
    // model row lives.
    final modeSeg = find.byType(DsSegment<String>).first;
    await tester.ensureVisible(modeSeg);
    await _settle(tester);
    await tester.tap(
      find.descendant(of: modeSeg, matching: find.byType(DsChip)).at(0),
    );
    await _settle(tester);
    // The chip row is a lazy horizontal list: swipe it until "Manage" exists.
    final manage = find.text(_lang == 'fr' ? 'Gérer' : 'Manage');
    final chips = find
        .ancestor(
          of: find.byType(ModelChip).first,
          matching: find.byType(ListView),
        )
        .first;
    for (var i = 0; i < 12 && manage.evaluate().isEmpty; i++) {
      await tester.drag(chips, const Offset(-300, 0));
      await _settle(tester);
    }
    await tester.ensureVisible(manage);
    await _settle(tester);
    await tester.tap(manage);
    await _settle(tester, const Duration(seconds: 3));
    await _shot(tester, '22_models');
    await tester.tap(find.byIcon(Icons.add).first);
    await _settle(tester);
    await _shot(tester, '23_model_add');
    await tester.binding.handlePopRoute();
    await _settle(tester);
    await tester.tap(
      find
          .descendant(
            of: find.byType(GridView),
            matching: find.byType(DsPressable),
          )
          .first,
    );
    await _settle(tester, const Duration(seconds: 4));
    await _shot(tester, '24_model_review');
    await tester.binding.handlePopRoute();
    await _settle(tester);
    await tester.binding.handlePopRoute();
    await _settle(tester);

    // Never worn, from the Profile tab.
    await tester.tap(tab(5));
    await _settle(tester);
    await tester.tap(find.byIcon(Icons.hourglass_empty));
    await _settle(tester, const Duration(seconds: 4));
    await _shot(tester, '25_dormant');
  });
}
