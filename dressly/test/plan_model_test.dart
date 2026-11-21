import 'package:dressly/models/plan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a day on an existing outfit is applied as that outfit', () {
    final plan = WeekPlan.fromJson({
      'days': [
        {
          'day': '2026-11-23',
          'cloth_ids': [1, 2],
          'outfit_id': 40,
          'outfit_thumb_url': '/thumb/generated/400/40.png',
          'source': 'outfit',
          'carried_ids': [],
        },
        {
          'day': '2026-11-24',
          'cloth_ids': [1, 3],
          'carried_ids': [1],
        },
      ],
    });
    expect(plan.outfits, {'2026-11-23': 40});
    expect(plan.applicable.keys, ['2026-11-23', '2026-11-24']);
    expect(plan.days[1].isContinued, isTrue);
    expect(plan.days[0].isContinued, isFalse);
    expect(plan.days[0].outfitThumbUrl, isNotEmpty);
  });

  test('options keep the hold rules when copied', () {
    final o = PlanOptions.defaults().copyWith(
      source: 'mix',
      holdDays: 2,
      holdByCategory: {'jogging': 3},
    );
    expect(o.source, 'mix');
    expect(o.holdDays, 2);
    expect(o.holdByCategory, {'jogging': 3});
    expect(o.algos.single.algo, 'random');
  });
}
