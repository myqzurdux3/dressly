/// How a real person puts clothes on, and where a garment lands on a canvas.
///
/// The same order as `generator.LAYER_ORDER` on the server, which decides the
/// stacking in a generated render. The two agreeing is the point: a jacket
/// belongs over the t-shirt in the manual builder and in the AI image alike.
///
/// Reported: "des fois ça affiche la veste en dessous du t shirt". On the
/// canvas the cause was that garments were painted in the order they happened
/// to be added, with no notion of what covers what.
library;

/// Innermost first. Shoes sit above socks and above the trouser hem; a bag
/// hangs over everything.
const Map<String, int> kLayerOrder = {
  'underwear': 10,
  'socks': 20,
  'jeans': 30, 'trousers': 30, 'shorts': 30, 'skirt': 30, 'jogging': 30,
  'dress': 35, // replaces top + bottom
  'tank-top': 40, 'tshirt': 42, 'polo': 44, 'shirt': 46,
  'sweatshirt': 50, 'hoodie': 52, // mid layer, over a t-shirt
  'jacket': 60, 'coat': 62, // outer, over everything worn
  'sneakers': 70, 'shoes': 70,
  'hat': 80, 'cap': 80,
  'bag': 90,
};

/// Unknown categories sit above the outer layer but below the shoes: visible,
/// never hiding a garment whose place we do know.
const int kDefaultLayer = 65;

/// Where a category sits in the stack — smaller is closer to the skin.
int layerRank(String category) =>
    kLayerOrder[category.trim().toLowerCase()] ?? kDefaultLayer;

/// Which part of the body a garment occupies. Two items in the same zone are
/// the ones that would land exactly on top of each other, so they are the only
/// ones a layout needs to spread apart.
String zoneOf(String category) {
  final r = layerRank(category);
  if (r >= 80) return 'head';
  if (r >= 70) return 'feet';
  if (r >= 40) return 'torso';
  if (r >= 20) return 'legs';
  return 'other';
}

/// Where a garment starts horizontally, as a fraction of the canvas.
///
/// The first item of a body zone is centred; a second one in the same zone (a
/// t-shirt and a jacket both on the torso) steps aside so both stay visible,
/// alternating right then left so the group stays balanced around the middle.
///
/// The builder used to offset EVERY item by 0.02 x its position in the list —
/// meant for duplicates on one row, applied to all of them, so a plain
/// three-piece outfit came out with each garment on its own slightly different
/// vertical axis and nothing was ever centred.
double defaultX(int occupantsInZone) {
  if (occupantsInZone <= 0) return 0.5;
  final step = 0.13 * ((occupantsInZone + 1) ~/ 2);
  final x = 0.5 + (occupantsInZone.isOdd ? step : -step);
  return x.clamp(0.12, 0.88);
}

