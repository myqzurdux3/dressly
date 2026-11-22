import '../models/costs.dart';
import '../models/credits.dart';
import '../models/report.dart';
import 'api_client.dart';

/// Admin-only reads. The server enforces the guard; this just asks.
class AdminService {
  AdminService(this._api);
  final ApiClient _api;

  Future<ApiCredits> credits() async {
    final data = await _api.get('/admin/credits') as Map<String, dynamic>;
    return ApiCredits.fromJson(data);
  }

  Future<GenerationCosts> costs() async {
    final data = await _api.get('/admin/costs') as Map<String, dynamic>;
    return GenerationCosts.fromJson(data);
  }

  /// Bad cut-out reports, unresolved first.
  Future<List<UserReport>> cutoutReports() async {
    final data = await _api.get('/notifications') as List;
    return [
      for (final j in data) UserReport.cutoutFromJson(j as Map<String, dynamic>),
    ];
  }

  /// Bad or failed generation reports, unresolved first.
  Future<List<UserReport>> generationReports() async {
    final data = await _api.get('/notifications/reports') as List;
    return [
      for (final j in data)
        UserReport.generationFromJson(j as Map<String, dynamic>),
    ];
  }

  /// Marks a cut-out report as handled.
  Future<void> resolveCutoutReport(int id) =>
      _api.post('/notifications/$id/resolve', const {});
}
