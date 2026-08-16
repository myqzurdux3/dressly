import '../models/agenda.dart';
import 'api_client.dart';

class AgendaService {
  AgendaService(this._api);
  final ApiClient _api;

  Future<List<AgendaEntry>> list({String? start, String? end}) async {
    final qs = <String>[];
    if (start != null) qs.add('start=$start');
    if (end != null) qs.add('end=$end');
    final path = '/agenda${qs.isEmpty ? '' : '?${qs.join('&')}'}';
    final data = await _api.get(path) as List;
    return data
        .map((e) => AgendaEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<AgendaEntry> create({
    required String day,
    int? outfitId,
    String title = '',
    String note = '',
  }) async {
    final data = await _api.post('/agenda', {
      'day': day,
      'outfit_id': outfitId,
      'title': title,
      'note': note,
    });
    return AgendaEntry.fromJson(data as Map<String, dynamic>);
  }

  /// Confirm (or un-confirm) that the planned outfit was worn. When confirming,
  /// the backend stamps last_worn_at on the outfit's clothes.
  Future<AgendaEntry> markWorn(int id, {bool worn = true}) async {
    final data = await _api.post('/agenda/$id/worn', {'worn': worn});
    return AgendaEntry.fromJson(data as Map<String, dynamic>);
  }

  Future<void> delete(int id) async {
    await _api.delete('/agenda/$id');
  }
}
