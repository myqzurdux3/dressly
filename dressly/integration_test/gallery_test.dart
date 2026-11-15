// Headless screenshots of the design-system gallery on the Linux target.
//
//   DISPLAY=:99 DRESSLY_WINDOW_SIZE=412x915 flutter test \
//     integration_test/gallery_test.dart -d linux --dart-define=SHOT_DIR=/abs
import 'dart:io';

import 'package:dressly/design/gallery/ds_gallery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _shotDir = String.fromEnvironment('SHOT_DIR', defaultValue: '/tmp');

Future<void> _wait(WidgetTester t, int ms) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _shot(WidgetTester t, String name) async {
  await _wait(t, 900);
  final r = await Process.run('import', [
    '-window',
    'root',
    '$_shotDir/$name.png',
  ]);
  if (r.exitCode != 0) fail('screenshot $name failed: ${r.stderr}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('gallery tour', (t) async {
    await t.pumpWidget(const DsGalleryApp());
    await _wait(t, 1000);
    for (final mode in ['dark', 'light']) {
      for (var i = 0; i < DsGalleryApp.tabCount; i++) {
        await t.tap(find.bySemanticsLabel(DsGalleryApp.tabLabels[i]));
        await _wait(t, 400);
        await _shot(t, '${mode}_${i}_a');
        await t.drag(find.byType(Scrollable).first, const Offset(0, -760));
        await _shot(t, '${mode}_${i}_b');
        await t.drag(find.byType(Scrollable).first, const Offset(0, 3000));
        await _wait(t, 300);
      }
      await t.tap(find.byKey(const ValueKey('gallery-brightness')));
      await _wait(t, 400);
    }
  });
}
