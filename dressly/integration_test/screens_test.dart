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
import 'package:flutter/widgets.dart';
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
  });
}
