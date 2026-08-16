import 'dart:convert';

import 'package:dressly/models/cloth.dart';
import 'package:dressly/services/api_client.dart';
import 'package:dressly/services/clothes_service.dart';
import 'package:dressly/services/outfits_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Captures the paths the services build, so the pagination contract with the
/// backend is pinned rather than assumed.
class _RecordingApi implements ApiClient {
  final List<String> paths = [];
  Object response = const <dynamic>[];

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

void main() {
  group('ClothesService.list', () {
    late _RecordingApi api;
    late ClothesService service;

    setUp(() {
      api = _RecordingApi();
      service = ClothesService(api);
    });

    test('sends no paging params when limit is omitted', () async {
      await service.list();
      expect(api.lastPath, '/clothes');
    });

    test('sends limit and offset when paging', () async {
      await service.list(limit: 30, offset: 60);
      final q = _queryOf(api.lastPath);
      expect(q['limit'], '30');
      expect(q['offset'], '60');
    });

    test('omits a zero offset', () async {
      await service.list(limit: 30);
      expect(_queryOf(api.lastPath).containsKey('offset'), isFalse);
    });

    test('combines filters with paging', () async {
      await service.list(
        filter: ClothFilter(sort: 'name', brand: 'NIKE', favorite: true),
        limit: 10,
        offset: 10,
      );
      final q = _queryOf(api.lastPath);
      expect(q['sort'], 'name');
      expect(q['brand'], 'NIKE');
      expect(q['favorite'], 'true');
      expect(q['limit'], '10');
      expect(q['offset'], '10');
    });

    test('parses the thumbnail URL the backend now returns', () async {
      api.response = [
        {
          'id': 1,
          'user_id': 1,
          'name': 'tee',
          'brand': '',
          'cut': 'normal',
          'category': 'tshirt',
          'custom_tags': <String>[],
          'colors': <dynamic>[],
          'images': [
            {
              'id': 5,
              'role': 'front',
              'sort_order': 0,
              'bg_accepted': 'accepted',
              'original_url': '/images/1/front_0.jpg?v=1',
              'cutout_url': '/images/1/front_0_cutout.webp?v=1',
              'thumb_url': '/thumb/images/400/1/front_0_cutout.webp?v=1',
            }
          ],
        }
      ];
      final clothes = await service.list();
      expect(clothes.single.thumbImageUrl,
          '/thumb/images/400/1/front_0_cutout.webp?v=1');
    });
  });

  group('OutfitsService.list', () {
    late _RecordingApi api;
    late OutfitsService service;

    setUp(() {
      api = _RecordingApi();
      service = OutfitsService(api);
    });

    test('always sends a sort, and paging only when asked', () async {
      await service.list();
      expect(_queryOf(api.lastPath)['sort'], 'newest');
      expect(_queryOf(api.lastPath).containsKey('limit'), isFalse);

      await service.list(limit: 20, offset: 40);
      final q = _queryOf(api.lastPath);
      expect(q['limit'], '20');
      expect(q['offset'], '40');
    });

    test('favorites endpoint pages too', () async {
      await service.favorites(limit: 20, offset: 20);
      expect(api.lastPath, startsWith('/outfits/favorites/list?'));
      final q = _queryOf(api.lastPath);
      expect(q['limit'], '20');
      expect(q['offset'], '20');
    });
  });

  group('ClothFilter', () {
    test('an empty filter produces an empty query', () {
      expect(ClothFilter().toQuery(), '');
      expect(ClothFilter().isEmpty, isTrue);
    });

    test('search terms are URL-encoded', () {
      final q = ClothFilter(search: 'blue & white').toQuery();
      expect(q, isNot(contains(' ')));
      expect(Uri.splitQueryString(q)['search'], 'blue & white');
    });

    test('clearSearch drops the term instead of keeping the old one', () {
      final f = ClothFilter(search: 'tee').copyWith(clearSearch: true);
      expect(f.search, isNull);
    });

    test('min_score is only sent when it filters something', () {
      expect(ClothFilter(minScore: 0).toQuery(), isNot(contains('min_score')));
      expect(ClothFilter(minScore: 3).toQuery(), contains('min_score=3'));
    });
  });

  group('Cloth.copyWith', () {
    final base = Cloth.fromJson(jsonDecode(jsonEncode({
      'id': 3,
      'user_id': 1,
      'name': 'tee',
      'brand': 'NIKE',
      'cut': 'slim',
      'category': 'tshirt',
      'custom_tags': ['a'],
      'colors': <dynamic>[],
      'images': <dynamic>[],
      'score': 4,
      'is_favorite': false,
    })) as Map<String, dynamic>);

    test('changes only the named field', () {
      final updated = base.copyWith(isFavorite: true);
      expect(updated.isFavorite, isTrue);
      expect(updated.id, base.id);
      expect(updated.name, base.name);
      expect(updated.brand, base.brand);
      expect(updated.score, base.score);
      expect(updated.customTags, base.customTags);
    });

    test('leaves the original untouched', () {
      base.copyWith(isFavorite: true);
      expect(base.isFavorite, isFalse);
    });
  });
}
