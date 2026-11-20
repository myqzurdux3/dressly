import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dressly/design/ds.dart';
import 'package:dressly/widgets/brand_logo.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: const ThemeF().themeData(Brightness.dark, DsAccent.orange),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('the mark is the launcher tag, at the asked size', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const DresslyMark(size: 80)));
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as ResizeImage).imageProvider, isA<AssetImage>());
    expect(
      ((image.image as ResizeImage).imageProvider as AssetImage).assetName,
      'assets/brand/mark.png',
    );
    expect(tester.getSize(find.byType(Image)), const Size(80, 80));
  });

  testWidgets('the lockup names the app once for screen readers', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_wrap(const DresslyLockup()));
    expect(find.text('DRESSLY'), findsOneWidget);
    expect(find.bySemanticsLabel('Dressly'), findsOneWidget);
    handle.dispose();
  });
}
