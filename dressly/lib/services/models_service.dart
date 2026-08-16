import 'dart:io';

import '../models/model.dart';
import 'api_client.dart';

class ModelsService {
  ModelsService(this._api);
  final ApiClient _api;

  Future<List<ModelEntity>> list({String search = ''}) async {
    final path = search.isEmpty ? '/models' : '/models?search=${Uri.encodeQueryComponent(search)}';
    final data = await _api.get(path) as List;
    return data.map((e) => ModelEntity.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<ModelEntity> get(int id) async {
    final data = await _api.get('/models/$id') as Map<String, dynamic>;
    return ModelEntity.fromJson(data);
  }

  Future<ModelEntity> create({
    required String name,
    String gender = '',
    required List<File> images,
  }) async {
    final data = await _api.postMultipart(
      '/models',
      fields: {'name': name, if (gender.isNotEmpty) 'gender': gender},
      files: images,
    );
    return ModelEntity.fromJson(data as Map<String, dynamic>);
  }

  /// Update a model's name and/or gender. Returns the updated model.
  Future<ModelEntity> update(int id, {String? name, String? gender}) async {
    final data = await _api.patch('/models/$id', {
      if (name != null) 'name': name,
      if (gender != null) 'gender': gender,
    }) as Map<String, dynamic>;
    return ModelEntity.fromJson(data);
  }

  Future<void> delete(int id) async {
    await _api.delete('/models/$id');
  }

  Future<void> acceptImage(int modelId, int imageId) async {
    await _api.post(
      '/models/$modelId/images/$imageId/accept',
      const <String, dynamic>{},
    );
  }

  Future<void> rejectImage(int modelId, int imageId) async {
    await _api.post(
      '/models/$modelId/images/$imageId/reject',
      const <String, dynamic>{},
    );
  }
}