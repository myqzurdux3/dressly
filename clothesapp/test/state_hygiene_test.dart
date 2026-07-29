import 'dart:io';

import 'package:clothesapp/services/image_cache_config.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two classes of bug that the analyzer does not catch and that only surface as
/// a red screen at runtime, so they are checked by reading the source.

List<File> _dartSources() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

void main() {
  group('setState hygiene', () {
    test('no setState closure returns a Future', () {
      // `setState(() => _future = service.call())` looks harmless, but an arrow
      // closure RETURNS what it assigns. Flutter asserts on that and throws
      // "setState() callback argument returned a Future", which is what the
      // profile screen did while its stats were still loading.
      final offenders = <String>[];
      final pattern = RegExp(
        r'setState\(\(\)\s*=>\s*\w+\s*=\s*[^;]*?'
        r'(Service\w*\(|ServiceOf\(context\)|\.me\(\)|\bawait\b)',
      );
      for (final f in _dartSources()) {
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (pattern.hasMatch(lines[i])) {
            offenders.add('${f.path}:${i + 1}  ${lines[i].trim()}');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'setState given a closure that returns a Future:\n'
              '${offenders.join('\n')}\n'
              'Use a block body: setState(() { x = ...; });');
    });

    test('no setState closure is marked async', () {
      final offenders = <String>[];
      for (final f in _dartSources()) {
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (RegExp(r'setState\(\(\)\s*async').hasMatch(lines[i])) {
            offenders.add('${f.path}:${i + 1}');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'an async setState callback returns a Future: $offenders');
    });
  });

  group('image cache', () {
    test('holds more files than a large wardrobe produces', () {
      // The shared default manager keeps 200 files. A ~110-cloth wardrobe
      // already exceeds that once front and back thumbnails are counted, so it
      // evicted entries as fast as it wrote them and every visit re-downloaded
      // everything.
      expect(AppImageCache.maxObjects, greaterThan(1000));
    });

    test('keeps entries long enough to be worth having', () {
      expect(AppImageCache.stalePeriod.inDays, greaterThanOrEqualTo(30));
    });

    test('uses its own store, separate from the package default', () {
      // Only the configuration is asserted: building the manager opens a real
      // cache directory through path_provider, which needs a running platform.
      expect(AppImageCache.key, isNot('libCachedImageData'));
      expect(AppImageCache.key, isNotEmpty);
    });

    testWidgets('raises the in-memory decoded-image budget', (tester) async {
      AppImageCache.configureMemoryCache();
      final cache = PaintingBinding.instance.imageCache;
      // Flutter's defaults are 100 MB / 1000 entries.
      expect(cache.maximumSizeBytes, greaterThan(100 << 20));
      expect(cache.maximumSize, greaterThanOrEqualTo(1000));
    });

    test('every network image goes through the configured manager', () {
      // AppImage is the single funnel for remote images. Anything else has no
      // disk cache at all (Image.network, NetworkImage) or silently uses the
      // 200-file default manager (a bare CachedNetworkImage).
      //
      // This originally only looked for CachedNetworkImage, and so missed nine
      // Image.network call sites — including the cloth detail screen, which
      // re-downloaded ~1.5 MB of lossless images every time it was opened.
      const forbidden = [
        'Image.network(',
        'NetworkImage(',
        // Uses the package's own 200-file cache instead of the app's.
        'CachedNetworkImageProvider(',
      ];
      // photo_edit_screen pairs a display widget with NetworkImage(...).resolve()
      // to measure the image for its crop overlay; the two must stay the same
      // provider, so it is exempt and deliberately re-fetches.
      const exempt = ['app_image.dart', 'photo_edit_screen.dart'];

      final offenders = <String>[];
      for (final f in _dartSources()) {
        if (exempt.any(f.path.endsWith)) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.trimLeft().startsWith('//')) continue;   // a comment about it
          for (final needle in forbidden) {
            if (line.contains(needle)) {
              offenders.add('${f.path}:${i + 1}  ${line.trim()}');
            }
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'these bypass the image cache — use AppImage or '
              'appImageProvider:\n${offenders.join('\n')}');
    });

    test('no screen renders a stored full-size image', () {
      // The stored cut-outs are lossless and around a megabyte. The access log
      // caught six of them being fetched in one session, at up to 1.2 MB, with
      // 98% of the time spent purely transferring bytes. Only the fullscreen
      // zoom viewers have any use for them.
      const exempt = [
        'app_image.dart',
        'photo_edit_screen.dart',   // pairs its widget with a measuring provider
        'image_review.dart',        // fullscreen zoom
        'outfit_viewer.dart',       // fullscreen zoom + download
        'cloth.dart',
        'model.dart',
      ];
      final offenders = <String>[];
      for (final f in _dartSources()) {
        if (exempt.any(f.path.endsWith)) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.trimLeft().startsWith('//')) continue;
          // Rendering the stored file rather than a server-made copy.
          //
          // Matches the accessor anywhere on the line, not just after a named
          // argument: the version that only looked for `url:` missed
          // `AppImage.path(cloth.displayImageUrl, ...)` — a positional
          // argument — which was loading the full wardrobe at ~756 KB a
          // picture in the cloth picker. It also missed displayImageUrl
          // entirely, having only listed displayUrl.
          final rendersFull = RegExp(
                  r'\b(displayUrl|displayImageUrl|cutoutUrl|originalUrl)\b')
              .hasMatch(line);
          // Fullscreen zoom is the one place the stored file is the point.
          final isFullscreen = line.contains('Fullscreen');
          if (rendersFull && !line.contains('Preview') && !isFullscreen) {
            offenders.add('${f.path}:${i + 1}  ${line.trim()}');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'these download the stored image instead of a preview:\n'
              '${offenders.join('\n')}');
    });

    test('detail screens ask for the preview size, not the stored image', () {
      // The stored cut-outs are lossless and ~1 MB; the 800 px copy is ~86 KB
      // and indistinguishable on a phone.
      final detail =
          File('lib/screens/cloth/cloth_detail_screen.dart').readAsStringSync();
      expect(detail, contains('displayPreviewUrl'),
          reason: 'the cloth detail screen should render the preview size');
    });
  });
}
