import 'dart:io';

import 'package:dressly/design/ds.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads the bundled design-system fonts so goldens show real glyphs instead
/// of the test font's boxes.
Future<void> loadDsFonts() async {
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final bytes = File('assets/fonts/$f').readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }

  await load(DsFonts.display, ['Anton-Regular.ttf']);
  await load(DsFonts.body, ['BricolageGrotesque[opsz,wdth,wght].ttf']);
  await load(DsFonts.mono, [
    'IBMPlexMono-Regular.ttf',
    'IBMPlexMono-Medium.ttf',
    'IBMPlexMono-SemiBold.ttf',
  ]);
}

/// Hosts a component the way a screen would: theme F, the page background,
/// a fixed width and an optional text scale.
Widget dsFrame(
  Widget child, {
  Brightness brightness = Brightness.dark,
  double width = 412,
  double textScale = 1,
  bool disableAnimations = false,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: const ThemeF().themeData(brightness, DsAccent.orange),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: disableAnimations,
        ),
        child: ColoredBox(
          color: context.ds.colors.bg,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Material(type: MaterialType.transparency, child: child),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Pins [child] as two goldens, dark and light, at 412×[height].
Future<void> expectDsGolden(
  WidgetTester t,
  Widget child,
  String name, {
  double height = 200,
  bool disableAnimations = true,
}) async {
  await t.binding.setSurfaceSize(Size(412, height));
  addTearDown(() => t.binding.setSurfaceSize(null));
  for (final b in Brightness.values) {
    await t.pumpWidget(
      dsFrame(child, brightness: b, disableAnimations: disableAnimations),
    );
    await t.pump(const Duration(seconds: 2));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/$name.${b.name}.png'),
    );
  }
}
