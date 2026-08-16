import 'package:clothesapp/models/layering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reported: "des fois ça affiche la veste en dessous du t shirt […] dans le
/// mode manuel ça fait pareil. Aussi des fois c'est pas aligné."
///
/// Both halves come from here: what covers what, and where an item starts on
/// the canvas.
void main() {
  group('layerRank', () {
    test('runs from the skin outwards', () {
      final order = [
        'underwear', 'socks', 'jeans', 'tshirt', 'hoodie', 'jacket',
      ].map(layerRank).toList();
      expect(order, orderedEquals([...order]..sort()));
    });

    test('a jacket is over a t-shirt, shoes over socks and trousers', () {
      expect(layerRank('jacket'), greaterThan(layerRank('tshirt')));
      expect(layerRank('shoes'), greaterThan(layerRank('socks')));
      expect(layerRank('shoes'), greaterThan(layerRank('jeans')));
      expect(layerRank('cap'), greaterThan(layerRank('coat')));
    });

    test('is case and whitespace insensitive', () {
      expect(layerRank('  JACKET '), layerRank('jacket'));
    });

    test('an unknown category hides nothing it should not', () {
      final unknown = layerRank('kimono-thing');
      expect(unknown, greaterThan(layerRank('jacket')));
      expect(unknown, lessThan(layerRank('shoes')));
    });

    test('matches the server order for every category it knows', () {
      // generator.LAYER_ORDER, copied. If the two drift, a canvas and its
      // generated render disagree about which garment is on top.
      const server = {
        'underwear': 10, 'socks': 20,
        'jeans': 30, 'trousers': 30, 'shorts': 30, 'skirt': 30, 'jogging': 30,
        'dress': 35,
        'tank-top': 40, 'tshirt': 42, 'polo': 44, 'shirt': 46,
        'sweatshirt': 50, 'hoodie': 52,
        'jacket': 60, 'coat': 62,
        'sneakers': 70, 'shoes': 70,
        'hat': 80, 'cap': 80, 'bag': 90,
      };
      expect(kLayerOrder, equals(server));
      expect(kDefaultLayer, 65); // generator._DEFAULT_LAYER
    });
  });

  group('zoneOf', () {
    test('groups the garments that would land on top of each other', () {
      expect(zoneOf('tshirt'), 'torso');
      expect(zoneOf('jacket'), 'torso');
      expect(zoneOf('jeans'), 'legs');
      expect(zoneOf('shoes'), 'feet');
      expect(zoneOf('cap'), 'head');
      expect(zoneOf('underwear'), 'other');
    });

    test('an unknown category shares the torso, where it is visible', () {
      expect(zoneOf('kimono-thing'), 'torso');
    });
  });

  group('defaultX', () {
    test('the first item of a zone is centred', () {
      expect(defaultX(0), 0.5);
    });

    test('the next ones alternate around the middle instead of drifting', () {
      final second = defaultX(1), third = defaultX(2);
      expect(second, greaterThan(0.5));
      expect(third, lessThan(0.5));
      // Balanced: equal steps either side, so a pair reads as deliberate.
      expect(second - 0.5, closeTo(0.5 - third, 1e-9));
    });

    test('stays on the canvas however many share a zone', () {
      for (var n = 0; n < 12; n++) {
        expect(defaultX(n), inInclusiveRange(0.12, 0.88));
      }
    });
  });
}
