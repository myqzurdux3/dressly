import 'package:flutter_test/flutter_test.dart';

import '../tool/perf_report.dart';

void main() {
  test('renders one row per traced action with frame stats', () {
    final md = renderPerfReport({
      'wardrobe_scroll': {
        'average_frame_build_time_millis': 4.2,
        '90th_percentile_frame_build_time_millis': 7.9,
        'average_frame_rasterizer_time_millis': 6.1,
        '90th_percentile_frame_rasterizer_time_millis': 11.3,
        'missed_frame_build_budget_count': 3,
        'missed_frame_rasterizer_budget_count': 5,
        'frame_count': 240,
      },
    }, {'clothes.list': 412});
    expect(md,
        contains('| wardrobe_scroll | 240 | 4.2 | 7.9 | 6.1 | 11.3 | 3 | 5 |'));
    expect(md, contains('| clothes.list | 412 |'));
  });
}
