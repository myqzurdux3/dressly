import '../models/stats.dart';
import 'api_client.dart';

class StatsService {
  StatsService(this._api);
  final ApiClient _api;

  Future<ProfileStats> me() async {
    final data = await _api.get('/stats/me');
    return ProfileStats.fromJson(data as Map<String, dynamic>);
  }
}
