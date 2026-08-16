import '../models/credits.dart';
import 'api_client.dart';

/// Admin-only reads. The server enforces the guard; this just asks.
class AdminService {
  AdminService(this._api);
  final ApiClient _api;

  Future<ApiCredits> credits() async {
    final data = await _api.get('/admin/credits') as Map<String, dynamic>;
    return ApiCredits.fromJson(data);
  }
}
