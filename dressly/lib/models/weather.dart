/// The forecast, reduced to what dressing needs: how warm, and which of the
/// two wardrobes that means.
class DayWeather {
  DayWeather({
    required this.available,
    required this.day,
    required this.mode,
    this.tempMax,
    this.code,
    this.place = '',
    this.reason = '',
  });

  /// False when there is no location set, the provider is unreachable, or the
  /// day is beyond the forecast. The screen shows the manual choice then —
  /// never an error.
  final bool available;

  final String day; // 'YYYY-MM-DD'

  /// 'hot' | 'cold' | 'any'. 'any' means "could not tell".
  final String mode;

  final double? tempMax;
  final int? code;
  final String place;

  /// Why it is unavailable, in the server's words — worth showing once rather
  /// than making the user guess whether they forgot to set a town.
  final String reason;

  bool get isHot => mode == 'hot';
  bool get isCold => mode == 'cold';

  /// "24°" — the daily maximum, which is what the mode is decided on.
  String get shortTemp => tempMax == null ? '' : '${tempMax!.round()}°';

  factory DayWeather.fromJson(Map<String, dynamic> j) => DayWeather(
        available: j['available'] == true,
        day: (j['day'] ?? '') as String,
        mode: (j['mode'] ?? 'any') as String,
        tempMax: (j['temp_max'] as num?)?.toDouble(),
        code: (j['code'] as num?)?.toInt(),
        place: (j['place'] ?? '') as String,
        reason: (j['reason'] ?? '') as String,
      );
}

/// Where the forecast is looked up. Stored on the account, not read from the
/// device — the app needs no location permission, and the answer does not
/// change because the phone spent an afternoon in another city.
class WeatherLocation {
  WeatherLocation({this.lat, this.lon, this.place = ''});

  final double? lat;
  final double? lon;
  final String place;

  bool get isSet => lat != null && lon != null;

  factory WeatherLocation.fromJson(Map<String, dynamic> j) => WeatherLocation(
        lat: (j['lat'] as num?)?.toDouble(),
        lon: (j['lon'] as num?)?.toDouble(),
        place: (j['place'] ?? '') as String,
      );
}

/// One hit from the town search.
class PlaceHit {
  PlaceHit({
    required this.name,
    required this.country,
    required this.admin,
    required this.lat,
    required this.lon,
  });

  final String name;
  final String country;
  final String admin;
  final double lat;
  final double lon;

  /// "Lyon, Auvergne-Rhône-Alpes, France" — enough to tell two Springfields
  /// apart, with the empty parts dropped rather than left as stray commas.
  String get label =>
      [name, admin, country].where((p) => p.trim().isNotEmpty).join(', ');

  factory PlaceHit.fromJson(Map<String, dynamic> j) => PlaceHit(
        name: (j['name'] ?? '') as String,
        country: (j['country'] ?? '') as String,
        admin: (j['admin'] ?? '') as String,
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
      );
}
