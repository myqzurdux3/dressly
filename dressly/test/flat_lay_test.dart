import 'package:flutter_test/flutter_test.dart';

import 'package:dressly/models/flat_lay.dart';

/// The manual builder's automatic arrangement: every garment inside the
/// canvas, none overlapping another, each kind in its band.
void main() {
  bool overlap(FlatSlot a, FlatSlot b) =>
      (a.x - b.x).abs() < (a.size + b.size) / 2 - 1e-9 &&
      (a.y - b.y).abs() < (a.size + b.size) / 2 - 1e-9;

  void check(Map<int, String> outfit) {
    final lay = flatLay(outfit.keys.toList(), (id) => outfit[id]!);
    expect(lay.keys.toSet(), outfit.keys.toSet());
    final slots = lay.values.toList();
    for (final s in slots) {
      expect(s.x - s.size / 2, greaterThanOrEqualTo(0));
      expect(s.y - s.size / 2, greaterThanOrEqualTo(0));
      expect(s.x + s.size / 2, lessThanOrEqualTo(1));
      expect(s.y + s.size / 2, lessThanOrEqualTo(1));
      expect(s.size, greaterThan(0.12), reason: 'nothing tiny');
    }
    for (var i = 0; i < slots.length; i++) {
      for (var j = i + 1; j < slots.length; j++) {
        expect(
          overlap(slots[i], slots[j]),
          isFalse,
          reason: '${slots[i]} vs ${slots[j]} in $outfit',
        );
      }
    }
  }

  test('every usual outfit lays out without overlap', () {
    check({1: 'tshirt', 2: 'jeans', 3: 'sneakers'});
    check({
      1: 'tshirt',
      2: 'hoodie',
      3: 'jacket',
      4: 'jogging',
      5: 'sneakers',
      6: 'socks',
      7: 'cap',
    });
    check({1: 'dress', 2: 'shoes', 3: 'bag'});
    check({1: 'coat'});
    check({1: 'jeans', 2: 'shorts'});
    check({1: 'sneakers', 2: 'socks', 3: 'cap', 4: 'bag', 5: 'scarf'});
    check({
      1: 'shirt',
      2: 'sweatshirt',
      3: 'jacket',
      4: 'coat',
      5: 'trousers',
      6: 'shoes',
      7: 'socks',
      8: 'hat',
      9: 'bag',
      10: 'underwear',
    });
  });

  test('upper body above, outermost on the left; bottoms below', () {
    final lay = flatLay(
      [1, 2, 3, 4],
      (id) => const {1: 'tshirt', 2: 'jacket', 3: 'jeans', 4: 'sneakers'}[id]!,
    );
    expect(lay[2]!.x, lessThan(lay[1]!.x)); // jacket left of the t-shirt
    expect(lay[1]!.y, closeTo(lay[2]!.y, 1e-9)); // on one line
    expect(lay[3]!.y, greaterThan(lay[1]!.y)); // jeans below
    expect(lay[4]!.x, greaterThan(lay[3]!.x)); // shoes beside the jeans
  });
}
