import 'dart:io';

import 'package:dressly/models/cloth.dart';
import 'package:dressly/services/api_client.dart';
import 'package:dressly/services/clothes_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Colour suggestions on the add form, before the garment exists.

class _Api implements ApiClient {
  final List<String> paths = [];
  final List<int> sizes = [];
  final List<List<Map<String, String>>> replies;
  _Api(this.replies);

  @override
  String? token;

  @override
  Future<dynamic> multipartBytes(
    String method,
    String path, {
    Map<String, String> fields = const {},
    required String fileField,
    required List<int> bytes,
    String filename = 'upload.png',
  }) async {
    paths.add('$method $path $fileField');
    sizes.add(bytes.length);
    return {'colors': replies[paths.length - 1]};
  }

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} not used by this test',
  );
}

void main() {
  test('front and back merge, each colour once at its strongest', () {
    final got = mergeDetectedColors([
      [
        ClothColor(color: 'Black', dominance: 'full'),
        ClothColor(color: 'White', dominance: 'little'),
      ],
      [
        ClothColor(color: 'White', dominance: 'part'),
        ClothColor(color: 'Red', dominance: 'little'),
      ],
    ]);
    expect(got.map((c) => '${c.color}:${c.dominance}'), [
      'Black:full',
      'White:part',
      'Red:little',
    ]);
  });

  test('both photos are sent to the photo endpoint and merged', () async {
    final dir = await Directory.systemTemp.createTemp('colors');
    final a = File('${dir.path}/a.jpg')..writeAsBytesSync([1, 2, 3]);
    final b = File('${dir.path}/b.jpg')..writeAsBytesSync([4, 5, 6]);
    final api = _Api([
      [
        {'color': 'Blue', 'dominance': 'full'},
      ],
      [
        {'color': 'Blue', 'dominance': 'part'},
        {'color': 'White', 'dominance': 'little'},
      ],
    ]);
    final got = await ClothesService(api).detectPhotoColors([a.path, b.path]);
    expect(api.paths, everyElement('POST /clothes/detect-colors image'));
    expect(api.paths, hasLength(2));
    // Undecodable bytes are sent as they are rather than dropped.
    expect(api.sizes, [3, 3]);
    expect(got.map((c) => c.color), ['Blue', 'White']);
    expect(got.first.dominance, 'full');
    await dir.delete(recursive: true);
  });
}
