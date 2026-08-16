import '../models/plan.dart';
import 'api_client.dart';

/// The week planner.
///
/// [preview] proposes and writes nothing; [apply] commits what the user
/// accepted. Keeping those apart is what stops a stray tap on "plan my week"
/// from rewriting an agenda somebody had already filled in.
class PlanService {
  PlanService(this._api);
  final ApiClient _api;

  /// Propose an outfit per day.
  ///
  /// [keep] holds the days the user pinned, with what is on them: they come
  /// back untouched, and their garments stay out of the other days.
  Future<WeekPlan> preview({
    String startDay = '',
    int days = 7,
    PlanOptions? options,
    Map<String, List<int>> keep = const {},
  }) async {
    final opts = options ?? PlanOptions.defaults();
    final data = await _api.post('/agenda/plan/preview', {
      'start_day': startDay,
      'days': days,
      'algos': [for (final a in opts.algos) a.toJson()],
      'min_score': opts.minScore,
      'fill_gaps': opts.fillGaps,
      'weather': opts.weather,
      'categories': opts.categories,
      'allow_repeat_theme': opts.allowRepeatTheme,
      'keep': keep,
    }) as Map<String, dynamic>;
    return WeekPlan.fromJson(data);
  }

  /// Write the accepted days into the agenda. Returns how many days were
  /// created and which were skipped (already planned, nothing to wear).
  Future<({int created, List<String> skipped})> apply(
      Map<String, List<int>> days, {bool replace = false}) async {
    final data = await _api.post('/agenda/plan/apply', {
      'days': days,
      'replace': replace,
    }) as Map<String, dynamic>;
    return (
      created: (data['created'] as List? ?? []).length,
      skipped: [
        for (final s in (data['skipped'] as List? ?? []))
          ((s as Map)['day'] ?? '') as String,
      ],
    );
  }

}
