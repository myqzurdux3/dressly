import 'package:dressly/design/gallery/ds_gallery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ds_harness.dart';

void main() {
  setUpAll(loadDsFonts);

  testWidgets('gallery builds every tab in dark and light without exceptions', (
    t,
  ) async {
    await t.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(const DsGalleryApp());
    for (final mode in ['light', 'dark']) {
      for (var i = 0; i < DsGalleryApp.tabCount; i++) {
        await t.tap(find.bySemanticsLabel(DsGalleryApp.tabLabels[i]));
        await t.pump(const Duration(seconds: 1));
        expect(t.takeException(), isNull, reason: '$mode tab $i');
        await t.drag(find.byType(Scrollable).first, const Offset(0, -3000));
        await t.pump(const Duration(seconds: 1));
        expect(t.takeException(), isNull, reason: '$mode tab $i scrolled');
      }
      await t.drag(find.byType(Scrollable).first, const Offset(0, 3000));
      await t.pump(const Duration(seconds: 1));
      await t.tap(find.byKey(const ValueKey('gallery-brightness')));
      await t.pump(const Duration(seconds: 1));
    }
  });
}
