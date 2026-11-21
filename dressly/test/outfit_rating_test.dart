import 'package:dressly/models/outfit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rating is read from the server and kept by copyWith', () {
    final o = Outfit.fromJson({'id': 1, 'rating': 4, 'is_favorite': false});
    expect(o.rating, 4);
    expect(o.copyWith(isFavorite: true).rating, 4);
    expect(o.copyWith(rating: 0).rating, 0);
    expect(o.withLinkedId(2).rating, 4);
    expect(Outfit.fromJson({'id': 2}).rating, 0);
  });
}
