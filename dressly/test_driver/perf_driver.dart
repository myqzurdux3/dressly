// Host side of integration_test/perf_test.dart: turns each traced action into
// build/perf/<action>.timeline_summary.json and the API timings into
// build/perf/api_ms.json, which tool/perf_report.dart reads.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:integration_test/integration_test_driver.dart';

const _outDir = 'build/perf';

Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    if (data == null) return;
    await Directory(_outDir).create(recursive: true);
    for (final MapEntry(:key, :value) in data.entries) {
      if (key == 'api_ms') {
        await File('$_outDir/api_ms.json').writeAsString(jsonEncode(value));
        continue;
      }
      final timeline = Timeline.fromJson(value as Map<String, dynamic>);
      await TimelineSummary.summarize(
        timeline,
      ).writeTimelineToFile(key, destinationDirectory: _outDir, pretty: true);
    }
  },
);
