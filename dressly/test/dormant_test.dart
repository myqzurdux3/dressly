import 'package:dressly/models/dormant.dart';
import 'package:dressly/services/api_client.dart';
import 'package:dressly/services/clothes_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The "never worn" list: what the server sends, and what the screen reads
/// off it.

class _RecordingApi implements ApiClient {
  final List<String> paths = [];
  Object response = const <String, dynamic>{};

  @override
  String? token;

  @override
  Future<dynamic> get(String path) async {
    paths.add(path);
    return response;
  }

  String get lastPath => paths.last;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not used by this test');
}

Map<String, String> _queryOf(String path) {
  final i = path.indexOf('?');
  if (i == -1) return {};
  return Uri.splitQueryString(path.substring(i + 1));
}

Map<String, dynamic> _cloth(int id, String name) => {
      'id': id,
      'user_id': 1,
      'name': name,
      'brand': '',
      'cut': 'normal',
      'category': 'tshirt',
      'custom_tags': <String>[],
      'colors': <dynamic>[],
      'images': <dynamic>[],
      'score': 0,
    };

Map<String, dynamic> _report({
  int months = 6,
  int count = 2,
  int wardrobe = 10,
  List<Map<String, dynamic>>? items,
}) =>
    {
      'months': months,
      'count': count,
      'wardrobe_count': wardrobe,
      'items': items ??
          [
            {
              ..._cloth(1, 'old shirt'),
              'dormant_days': 412,
              'dormant_since': '2025-06-13',
              'never_worn': false,
              'times_worn': 3,
            },
            {
              ..._cloth(2, 'tag still on'),
              'dormant_days': 200,
              'dormant_since': '2026-01-11',
              'never_worn': true,
              'times_worn': 0,
            },
          ],
    };

void main() {
  group('ClothesService.dormant', () {
    late _RecordingApi api;
    late ClothesService service;

    setUp(() {
      api = _RecordingApi();
      service = ClothesService(api);
      api.response = _report();
    });

    test('asks for six months by default', () async {
      await service.dormant();
      expect(_queryOf(api.lastPath)['months'], '6');
      expect(api.lastPath, startsWith('/clothes/dormant'));
    });

    test('passes the chosen threshold', () async {
      await service.dormant(months: 12);
      expect(_queryOf(api.lastPath)['months'], '12');
    });

    test('sends paging only when asked', () async {
      await service.dormant();
      expect(_queryOf(api.lastPath).containsKey('limit'), isFalse);
      await service.dormant(limit: 20, offset: 40);
      final q = _queryOf(api.lastPath);
      expect(q['limit'], '20');
      expect(q['offset'], '40');
    });

    test('parses the items and the totals', () async {
      final report = await service.dormant();
      expect(report.months, 6);
      expect(report.count, 2);
      expect(report.wardrobeCount, 10);
      expect(report.items.map((i) => i.cloth.name),
          orderedEquals(['old shirt', 'tag still on']));
      expect(report.items.first.dormantDays, 412);
      expect(report.items.first.timesWorn, 3);
      expect(report.items.first.neverWorn, isFalse);
      expect(report.items.last.neverWorn, isTrue);
    });
  });

  group('DormantReport', () {
    test('says what share of the wardrobe is sitting unworn', () {
      final r = DormantReport.fromJson(_report(count: 38, wardrobe: 150));
      expect(r.percentOfWardrobe, 25);
    });

    test('keeps the two kinds apart', () {
      // The reported bug was one rule for both: a wardrobe of never-worn
      // clothes younger than the threshold came back empty. They are counted
      // and shown separately now.
      final r = DormantReport.fromJson({
        ..._report(count: 2),
        'never_worn_count': 1,
        'stale_count': 1,
      });
      expect(r.neverWornCount, 1);
      expect(r.staleCount, 1);
      expect(r.neverWorn.map((i) => i.cloth.name), ['tag still on']);
      expect(r.stale.map((i) => i.cloth.name), ['old shirt']);
    });

    test('an older server that sends neither count still parses', () {
      final r = DormantReport.fromJson(_report(count: 2));
      expect(r.neverWornCount, 0);
      expect(r.graceDays, greaterThan(0));
    });

    test('an empty wardrobe is 0%, not a division by nothing', () {
      final r = DormantReport.fromJson(
          _report(count: 0, wardrobe: 0, items: const []));
      expect(r.percentOfWardrobe, 0);
      expect(r.isEmpty, isTrue);
    });

    test('a response with no items at all is still readable', () {
      final r = DormantReport.fromJson(const <String, dynamic>{});
      expect(r.items, isEmpty);
      expect(r.months, 6);
      expect(r.count, 0);
    });
  });

  group('DormantCloth', () {
    test('rounds down to whole months for the label', () {
      final j = {
        ..._cloth(1, 'x'),
        'dormant_days': 412,
        'dormant_since': '2025-06-13',
        'never_worn': false,
        'times_worn': 1,
      };
      // 412 days reads as "13 months", not "412 days".
      expect(DormantCloth.fromJson(j).dormantMonths, 13);
    });

    test('under a month there are no months to show', () {
      final j = {
        ..._cloth(1, 'x'),
        'dormant_days': 20,
        'dormant_since': '2026-07-10',
        'never_worn': true,
        'times_worn': 0,
      };
      expect(DormantCloth.fromJson(j).dormantMonths, 0);
    });
  });
}
