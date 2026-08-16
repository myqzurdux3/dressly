import 'package:dressly/models/plan.dart';
import 'package:dressly/services/api_client.dart';
import 'package:dressly/services/plan_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The week planner's client half: what it sends, and what it makes of the
/// answer. The property that matters most is that previewing and saving are
/// two different calls — a proposal must never write anything.

class _RecordingApi implements ApiClient {
  final List<String> paths = [];
  final List<Map<String, dynamic>> bodies = [];
  Object response = const <String, dynamic>{};

  @override
  String? token;

  @override
  Future<dynamic> get(String path) async {
    paths.add(path);
    return response;
  }

  @override
  Future<dynamic> post(String path, Map<String, dynamic> body) async {
    paths.add(path);
    bodies.add(body);
    return response;
  }

  String get lastPath => paths.last;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not used by this test');
}

Map<String, dynamic> _day(String day, List<int> ids,
        {bool locked = false,
        bool repeated = false,
        String mode = 'hot',
        bool available = true,
        double? temp = 24.0}) =>
    {
      'day': day,
      'cloth_ids': ids,
      'cloths': [
        for (final id in ids)
          {'id': id, 'name': 'garment $id', 'brand': '', 'category': 'tshirt',
           'thumb_url': '/thumb/images/400/$id.webp'},
      ],
      'locked': locked,
      'repeated': repeated,
      'weather': {'mode': mode, 'available': available, 'temp_max': temp},
    };

void main() {
  late _RecordingApi api;
  late PlanService service;

  setUp(() {
    api = _RecordingApi();
    service = PlanService(api);
  });

  group('preview', () {
    test('asks for a week from today by default', () async {
      api.response = {'algo': 'random', 'days': []};
      await service.preview();
      expect(api.lastPath, '/agenda/plan/preview');
      expect(api.bodies.last['days'], 7);
      expect(api.bodies.last['weather'], 'auto');
      expect(api.bodies.last['start_day'], '');
    });

    test('sends the whole mix, in the order it was built', () async {
      api.response = {'algos': ['same-brand', 'random'], 'days': []};
      await service.preview(
          options: const PlanOptions(algos: [
        PlanAlgoChoice(algo: 'same-brand'),
        PlanAlgoChoice(algo: 'pick-by-color', color: 'Green'),
        PlanAlgoChoice(algo: 'random'),
      ]));
      final sent = api.bodies.last['algos'] as List;
      expect(sent.map((e) => (e as Map)['algo']),
          orderedEquals(['same-brand', 'pick-by-color', 'random']));
      expect((sent[1] as Map)['color'], 'Green');
    });

    test('sends the rest of the sheet too', () async {
      api.response = {'days': []};
      await service.preview(
          options: const PlanOptions(
        algos: [PlanAlgoChoice(algo: 'random')],
        weather: 'cold',
        categories: ['tshirt', 'jeans'],
        minScore: 3,
        fillGaps: false,
        allowRepeatTheme: true,
      ));
      final body = api.bodies.last;
      expect(body['weather'], 'cold');
      expect(body['categories'], ['tshirt', 'jeans']);
      expect(body['min_score'], 3);
      expect(body['fill_gaps'], isFalse);
      expect(body['allow_repeat_theme'], isTrue);
    });

    test('the default asks for variety, not one repeated theme', () {
      final d = PlanOptions.defaults();
      expect(d.allowRepeatTheme, isFalse);
      expect(d.weather, 'auto');
      expect(d.algos, isNotEmpty);
    });

    test('reads back which algorithm dressed each day', () async {
      api.response = {
        'algos': ['same-brand', 'random'],
        'days': [
          {..._day('2026-08-04', [1]), 'algo': 'same-brand', 'theme': 'NIKE'},
          {..._day('2026-08-05', [2]), 'algo': 'random'},
        ],
      };
      final plan = await service.preview();
      expect(plan.days.first.algo, 'same-brand');
      expect(plan.days.first.theme, 'NIKE');
      expect(plan.days.last.theme, isEmpty);
    });

    test('sends the pinned days so they come back untouched', () async {
      api.response = {'algo': 'random', 'days': []};
      await service.preview(keep: {
        '2026-08-04': [1, 2, 3]
      });
      expect(api.bodies.last['keep'], {
        '2026-08-04': [1, 2, 3]
      });
    });

    test('reads a proposed week', () async {
      api.response = {
        'algo': 'random',
        'days': [
          _day('2026-08-04', [1, 2]),
          _day('2026-08-05', [3, 4], mode: 'cold', temp: 8.0),
        ],
      };
      final plan = await service.preview();
      expect(plan.days, hasLength(2));
      expect(plan.days.first.clothIds, [1, 2]);
      expect(plan.days.first.cloths.first.thumbUrl, isNotEmpty);
      expect(plan.days.first.shortTemp, '24°');
      expect(plan.days.last.weatherMode, 'cold');
    });

    test('a day the wardrobe could not fill is empty, not missing', () async {
      api.response = {
        'algo': 'random',
        'days': [_day('2026-08-04', const [])],
      };
      final plan = await service.preview();
      expect(plan.days, hasLength(1));
      expect(plan.days.first.isEmpty, isTrue);
      expect(plan.isEmpty, isTrue);
    });

    test('a repeated day is flagged so the screen can say so', () async {
      api.response = {
        'algo': 'random',
        'days': [_day('2026-08-04', [1], repeated: true)],
      };
      expect((await service.preview()).days.first.repeated, isTrue);
    });
  });

  group('applicable', () {
    test('is what saving would write, skipping the empty days', () {
      final plan = WeekPlan.fromJson({
        'days': [
          _day('2026-08-04', [1, 2]),
          _day('2026-08-05', const []),
          _day('2026-08-06', [3]),
        ],
      });
      expect(plan.applicable, {
        '2026-08-04': [1, 2],
        '2026-08-06': [3],
      });
    });
  });

  group('apply', () {
    test('posts the days and reports what was skipped', () async {
      api.response = {
        'created': [
          {'day': '2026-08-04', 'entry_id': 1, 'outfit_id': 9},
        ],
        'skipped': [
          {'day': '2026-08-05', 'reason': 'already planned'},
        ],
      };
      final result = await service.apply({
        '2026-08-04': [1, 2],
        '2026-08-05': [3],
      });
      expect(api.lastPath, '/agenda/plan/apply');
      expect(result.created, 1);
      expect(result.skipped, ['2026-08-05']);
    });

    test('does not replace by default', () async {
      api.response = {'created': [], 'skipped': []};
      await service.apply({'2026-08-04': [1]});
      expect(api.bodies.last['replace'], isFalse);
    });
  });

  group('algoNeedsValue', () {
    // Reported: "quand je click sur aléatoire ça me demande quel tag", and
    // "des modes du générateur normal manquent dans celui de la semaine".
    // One cause: the server says needs: "none", and the sheet tested for an
    // EMPTY string — so every argument-free algorithm was sent down the
    // ask-for-a-value path, whose fallback asked for a tag.
    test('the argument-free algorithms need nothing', () {
      for (final n in ['none', 'NONE', ' none ', '']) {
        expect(algoNeedsValue(n), isFalse, reason: n);
      }
    });

    test('only the pick-by-* kinds ask for a value', () {
      expect(algoNeedsValue('color'), isTrue);
      expect(algoNeedsValue('brand'), isTrue);
      expect(algoNeedsValue('tag'), isTrue);
    });

    test('an unknown kind is not treated as a tag', () {
      // The old fallback turned anything it did not recognise into "Which
      // tag?"; a new server-side kind must not silently become one.
      expect(algoNeedsValue('season'), isFalse);
    });
  });

  group('PlanDay', () {
    test('pinning a day keeps everything else about it', () {
      final day = PlanDay.fromJson(_day('2026-08-04', [1, 2]));
      final pinned = day.copyWith(locked: true);
      expect(pinned.locked, isTrue);
      expect(pinned.clothIds, day.clothIds);
      expect(pinned.cloths.length, day.cloths.length);
      expect(pinned.tempMax, day.tempMax);
    });
  });
}
