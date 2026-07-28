import 'outfit.dart';

class TopCloth {
  final int id;
  final String name;
  final String brand;
  final int timesWorn;
  final String thumbUrl;
  TopCloth({
    required this.id,
    required this.name,
    required this.brand,
    required this.timesWorn,
    required this.thumbUrl,
  });
  factory TopCloth.fromJson(Map<String, dynamic> j) => TopCloth(
        id: j['id'] as int,
        name: (j['name'] ?? '') as String,
        brand: (j['brand'] ?? '') as String,
        timesWorn: j['times_worn'] as int? ?? 0,
        thumbUrl: (j['thumb_url'] ?? '') as String,
      );
}

class ProfileStats {
  final int clothesCount;
  final int clothesWornCount;
  final int clothesWornPct;
  final int outfitsGenerated;
  final int outfitsCount;
  final int favoritesCount;
  final int outfitWearsTotal;
  final int clothWearsTotal;
  final Outfit? mostWornOutfit;
  final int mostWornOutfitTimes;
  final List<TopCloth> topClothes;

  ProfileStats({
    required this.clothesCount,
    required this.clothesWornCount,
    required this.clothesWornPct,
    required this.outfitsGenerated,
    required this.outfitsCount,
    required this.favoritesCount,
    required this.outfitWearsTotal,
    required this.clothWearsTotal,
    required this.mostWornOutfit,
    required this.mostWornOutfitTimes,
    required this.topClothes,
  });

  factory ProfileStats.fromJson(Map<String, dynamic> j) {
    final mwo = j['most_worn_outfit'] as Map<String, dynamic>?;
    return ProfileStats(
      clothesCount: j['clothes_count'] as int? ?? 0,
      clothesWornCount: j['clothes_worn_count'] as int? ?? 0,
      clothesWornPct: j['clothes_worn_pct'] as int? ?? 0,
      outfitsGenerated: j['outfits_generated'] as int? ?? 0,
      outfitsCount: j['outfits_count'] as int? ?? 0,
      favoritesCount: j['favorites_count'] as int? ?? 0,
      outfitWearsTotal: j['outfit_wears_total'] as int? ?? 0,
      clothWearsTotal: j['cloth_wears_total'] as int? ?? 0,
      mostWornOutfit: mwo == null
          ? null
          : Outfit.fromJson(mwo['outfit'] as Map<String, dynamic>),
      mostWornOutfitTimes: mwo == null ? 0 : (mwo['times_worn'] as int? ?? 0),
      topClothes: ((j['top_clothes'] as List?) ?? const [])
          .map((e) => TopCloth.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
