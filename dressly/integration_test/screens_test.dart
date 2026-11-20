// Visual tour of the app on the Linux desktop target: logs in, visits each
// tab and the first garment, and saves a screenshot of each.
//
//   DISPLAY=:99 DRESSLY_WINDOW_SIZE=412x915 flutter test \
//     integration_test/screens_test.dart -d linux \
//     --dart-define=PERF_EMAIL=... --dart-define=PERF_PASSWORD=... \
//     --dart-define=SHOT_DIR=/abs/path
//
// Screenshots are taken with ImageMagick `import` on the X display, so they
// show exactly what was rendered. Credentials only come from the command line.
import 'dart:io';

import 'package:dressly/main.dart';
import 'package:dressly/screens/home/home_shell.dart';
import 'package:dressly/services/auth_service.dart';
import 'package:dressly/design/ds.dart';
import 'package:dressly/screens/wardrobe/wardrobe_card.dart';
import 'package:dressly/widgets/outfit_history_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _email = String.fromEnvironment('PERF_EMAIL');
const _password = String.fromEnvironment('PERF_PASSWORD');
const _shotDir = String.fromEnvironment('SHOT_DIR', defaultValue: '/tmp');

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
    await const AuthService().login(_email, _password);
    await tester.pumpWidget(await bootstrap());
    await _settle(tester, const Duration(seconds: 6));
    expect(find.byType(HomeShell), findsOneWidget);

    await _shot(tester, '01_wardrobe');
    Finder tab(int i) => find.descendant(
      of: find.byType(DsTabBar),
      matching: find.byIcon(HomeShell.tabIcons[i]),
    );
    const names = ['02_create', '03_agenda', '04_saved', '05_profile'];
    for (var i = 1; i <= 4; i++) {
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
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await _settle(tester);
    await tester.tap(cards.first);
    await _settle(tester, const Duration(seconds: 3));
    await _shot(tester, '11_result');
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -700));
    await _settle(tester);
    await _shot(tester, '12_result_bottom');
    await tester.binding.handlePopRoute(); // close the result
    await _settle(tester);

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
        find.descendant(of: seg, matching: find.byType(DsChip)).at(1));
    await _settle(tester);
    await tester.tap(find.byIcon(Icons.brush));
    await _settle(tester, const Duration(seconds: 3));
    await _shot(tester, '15_builder');
    await tester.binding.handlePopRoute();
    await _settle(tester);

    // The week planner and its options, from the Agenda tab.
    await tester.tap(tab(2));
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
    await tester.tap(tab(4));
    await _settle(tester);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await _settle(tester);
    await _shot(tester, '18_settings');
    var n = 19;
    for (final icon in const [
      Icons.wb_sunny_outlined,
      Icons.account_balance_wallet_outlined,
      Icons.lock_outline,
    ]) {
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
  });
}
