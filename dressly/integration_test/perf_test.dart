// On-device performance run. Drives the real app (real backend, real images)
// in profile mode and records frame timings per action.
//
//   flutter drive --profile --no-dds \
//     --driver=test_driver/perf_driver.dart \
//     --target=integration_test/perf_test.dart \
//     --dart-define=PERF_EMAIL=... --dart-define=PERF_PASSWORD=...
//
// Credentials only ever come from the command line.
import 'package:dressly/main.dart';
import 'package:dressly/screens/home/home_shell.dart';
import 'package:dressly/services/api_client.dart';
import 'package:dressly/services/auth_service.dart';
import 'package:dressly/services/clothes_service.dart';
import 'package:dressly/widgets/cloth_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _email = String.fromEnvironment('PERF_EMAIL');
const _password = String.fromEnvironment('PERF_PASSWORD');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('perf run', (tester) async {
    if (_email.isEmpty || _password.isEmpty) {
      fail('Pass --dart-define=PERF_EMAIL=... --dart-define=PERF_PASSWORD=...');
    }

    // login() stores the token, so bootstrap() takes the normal restore path.
    final auth = await const AuthService().login(_email, _password);
    await tester.pumpWidget(await bootstrap());
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (find.byType(HomeShell).evaluate().isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        fail('login did not reach HomeShell');
      }
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle();

    final apiMs = <String, int>{};
    final clothes = ClothesService(ApiClient(token: auth.token));
    final watch = Stopwatch()..start();
    await clothes.list(limit: 30);
    apiMs['clothes.list'] = watch.elapsedMilliseconds;

    await binding.traceAction(() async {
      final grid = find.byType(CustomScrollView).first;
      for (var i = 0; i < 3; i++) {
        await tester.fling(grid, const Offset(0, -1200), 3000);
        await tester.pumpAndSettle();
      }
      for (var i = 0; i < 3; i++) {
        await tester.fling(grid, const Offset(0, 1200), 3000);
        await tester.pumpAndSettle();
      }
    }, reportKey: 'wardrobe_scroll');

    await binding.traceAction(() async {
      await tester.tap(find.byType(ClothCard).first);
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
    }, reportKey: 'cloth_detail_open');

    await binding.traceAction(() async {
      final tabs = find.byType(NavigationDestination);
      for (final i in [1, 2, 3, 4, 0]) {
        await tester.tap(tabs.at(i));
        await tester.pumpAndSettle();
      }
    }, reportKey: 'tab_switch');

    binding.reportData!['api_ms'] = apiMs;
  });
}
