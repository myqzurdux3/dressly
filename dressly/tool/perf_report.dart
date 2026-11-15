// Turns the files written by test_driver/perf_driver.dart into a Markdown
// report. Run from the app folder after a `flutter drive --profile` run:
//
//   dart run tool/perf_report.dart
import 'dart:convert';
import 'dart:io';

const _summarySuffix = '.timeline_summary.json';

/// Renders traced actions (frame stats from `TimelineSummary`) and timed API
/// calls as two Markdown tables. Numbers are printed as recorded: the report
/// compares runs, it does not interpret them.
String renderPerfReport(
  Map<String, Map<String, dynamic>> summaries,
  Map<String, int> apiMs,
) {
  final out = StringBuffer()
    ..writeln(
      '| action | frames | build avg | build p90 | raster avg '
      '| raster p90 | build missed | raster missed |',
    )
    ..writeln('|---|---|---|---|---|---|---|---|');
  for (final MapEntry(key: action, value: s) in summaries.entries) {
    final cells = [
      action,
      s['frame_count'],
      s['average_frame_build_time_millis'],
      s['90th_percentile_frame_build_time_millis'],
      s['average_frame_rasterizer_time_millis'],
      s['90th_percentile_frame_rasterizer_time_millis'],
      s['missed_frame_build_budget_count'],
      s['missed_frame_rasterizer_budget_count'],
    ];
    out.writeln('| ${cells.join(' | ')} |');
  }
  out
    ..writeln()
    ..writeln('| api call | ms |')
    ..writeln('|---|---|');
  for (final MapEntry(key: call, value: ms) in apiMs.entries) {
    out.writeln('| $call | $ms |');
  }
  return out.toString();
}

void main(List<String> args) {
  final dir = Directory(args.isEmpty ? 'build/perf' : args.first);
  final summaries = <String, Map<String, dynamic>>{};
  for (final f in dir.listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    if (!name.endsWith(_summarySuffix)) continue;
    summaries[name.substring(0, name.length - _summarySuffix.length)] =
        jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  }
  final apiFile = File('${dir.path}/api_ms.json');
  final apiMs = apiFile.existsSync()
      ? (jsonDecode(apiFile.readAsStringSync()) as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, (v as num).toInt()),
        )
      : <String, int>{};
  stdout.write(renderPerfReport(summaries, apiMs));
}
