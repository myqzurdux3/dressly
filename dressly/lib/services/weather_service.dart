import '../models/weather.dart';
import 'api_client.dart';

/// Forecast lookups and the account's location.
///
/// Nothing here throws for "no forecast": the server answers
/// `available: false`, and the caller shows the manual choice. A weather outage
/// must not be something the outfit screen has to handle.
class WeatherService {
  WeatherService(this._api);
  final ApiClient _api;

  /// Today's forecast, or [day] when planning ahead ('YYYY-MM-DD').
  Future<DayWeather> forecast({String? day}) async {
    final path = day == null || day.isEmpty
        ? '/weather'
        : '/weather?day=${Uri.encodeQueryComponent(day)}';
    final data = await _api.get(path) as Map<String, dynamic>;
    return DayWeather.fromJson(data);
  }

  /// Where the forecast is looked up for this account.
  Future<WeatherLocation> location() async {
    final data = await _api.get('/weather/location') as Map<String, dynamic>;
    return WeatherLocation.fromJson(data);
  }

  /// Set the location, or clear it by passing nothing.
  Future<WeatherLocation> setLocation(
      {double? lat, double? lon, String place = ''}) async {
    final data = await _api.put('/weather/location', {
      'lat': lat,
      'lon': lon,
      'place': place,
    }) as Map<String, dynamic>;
    return WeatherLocation.fromJson(data);
  }

  /// Town search. Returns an empty list for a query too short to be useful or
  /// when the provider is unreachable.
  Future<List<PlaceHit>> searchPlaces(String query, {String lang = 'en'}) async {
    if (query.trim().length < 2) return const [];
    final data = await _api.get(
        '/weather/places?q=${Uri.encodeQueryComponent(query.trim())}&lang=$lang')
        as Map<String, dynamic>;
    return [
      for (final raw in (data['places'] as List? ?? []))
        PlaceHit.fromJson((raw as Map).cast<String, dynamic>()),
    ];
  }
}
