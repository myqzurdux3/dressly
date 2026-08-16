import 'package:dressly/models/weather.dart';
import 'package:dressly/services/api_client.dart';
import 'package:dressly/services/weather_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The forecast side of the app: what it asks the server, and how it reads the
/// answer. The rule the tests keep pinning is that "no forecast" is a normal
/// answer, never an error the screens have to handle.

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
  Future<dynamic> put(String path, Map<String, dynamic> body) async {
    paths.add(path);
    bodies.add(body);
    return response;
  }

  String get lastPath => paths.last;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not used by this test');
}

void main() {
  late _RecordingApi api;
  late WeatherService service;

  setUp(() {
    api = _RecordingApi();
    service = WeatherService(api);
  });

  group('forecast', () {
    test('asks about today by default and about a day when given one', () async {
      api.response = {'available': true, 'day': '2026-07-30', 'mode': 'hot'};
      await service.forecast();
      expect(api.lastPath, '/weather');
      await service.forecast(day: '2026-08-02');
      expect(api.lastPath, '/weather?day=2026-08-02');
    });

    test('reads a usable forecast', () async {
      api.response = {
        'available': true,
        'day': '2026-07-30',
        'mode': 'hot',
        'temp_max': 27.4,
        'temp_min': 18.0,
        'place': 'Lyon',
      };
      final w = await service.forecast();
      expect(w.available, isTrue);
      expect(w.isHot, isTrue);
      expect(w.isCold, isFalse);
      expect(w.shortTemp, '27°'); // rounded, because nobody dresses by decimals
      expect(w.place, 'Lyon');
    });

    test('an unavailable forecast is a normal answer, not an exception',
        () async {
      api.response = {
        'available': false,
        'day': '2026-07-30',
        'mode': 'any',
        'reason': 'no location set',
      };
      final w = await service.forecast();
      expect(w.available, isFalse);
      expect(w.mode, 'any');
      expect(w.isHot, isFalse);
      expect(w.isCold, isFalse);
      expect(w.reason, isNotEmpty);
      expect(w.shortTemp, '', reason: 'no temperature to show');
    });
  });

  group('location', () {
    test('saves a chosen town', () async {
      api.response = {'lat': 45.75, 'lon': 4.85, 'place': 'Lyon, France'};
      final saved =
          await service.setLocation(lat: 45.75, lon: 4.85, place: 'Lyon, France');
      expect(api.lastPath, '/weather/location');
      expect(api.bodies.last['lat'], 45.75);
      expect(saved.isSet, isTrue);
    });

    test('clearing sends nulls rather than omitting the fields', () async {
      // The server reads a missing key as "unchanged"; an explicit null is what
      // says "forget where I am".
      api.response = {'lat': null, 'lon': null, 'place': ''};
      final cleared = await service.setLocation();
      expect(api.bodies.last.containsKey('lat'), isTrue);
      expect(api.bodies.last['lat'], isNull);
      expect(cleared.isSet, isFalse);
    });

    test('half a location does not count as set', () {
      expect(WeatherLocation(lat: 45.75).isSet, isFalse);
      expect(WeatherLocation(lat: 45.75, lon: 4.85).isSet, isTrue);
    });
  });

  group('place search', () {
    test('does not ask the server about a one-letter query', () async {
      expect(await service.searchPlaces('l'), isEmpty);
      expect(api.paths, isEmpty, reason: 'the request was sent anyway');
    });

    test('sends the query and the interface language', () async {
      api.response = {'places': []};
      await service.searchPlaces('Saint-Étienne', lang: 'fr');
      expect(api.lastPath, contains('lang=fr'));
      expect(api.lastPath, contains('q=Saint-%C3%89tienne'),
          reason: 'the query must be URL-encoded');
    });

    test('labels a hit with enough to tell two towns apart', () async {
      api.response = {
        'places': [
          {
            'name': 'Springfield',
            'admin': 'Illinois',
            'country': 'United States',
            'lat': 39.8,
            'lon': -89.6,
          },
        ],
      };
      final hits = await service.searchPlaces('springfield');
      expect(hits.single.label, 'Springfield, Illinois, United States');
    });

    test('a hit missing its region has no stray comma', () {
      final hit = PlaceHit.fromJson(
          {'name': 'Monaco', 'admin': '', 'country': 'Monaco',
           'lat': 43.7, 'lon': 7.4});
      expect(hit.label, 'Monaco, Monaco');
    });
  });
}
