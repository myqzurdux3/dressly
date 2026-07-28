import 'package:flutter/material.dart';

import '../../app.dart';
import '../../l10n/app_text.dart';
import '../../models/cloth.dart';
import '../../services/outfits_service.dart';

class AlgoPick {
  final String algo;
  final int minScore;
  final String color;
  final String brand;
  final String tag;
  final int count;
  final String weather; // 'any' | 'hot' | 'cold'
  final List<String> categories; // explicit category choices (overrides weather)
  final bool fillGaps; // fill missing roles (e.g. shoes) from any cloth
  AlgoPick({
    required this.algo,
    this.minScore = 0,
    this.color = '',
    this.brand = '',
    this.tag = '',
    this.count = 1,
    this.weather = 'any',
    this.categories = const [],
    this.fillGaps = false,
  });
}

/// Sheet that asks the user which generator algorithm to run, plus optional
/// parameters (color / brand for pick-by-* and a min-score filter that uses
/// only clothes rated at or above this score). The model, "describe items" and
/// extra prompt are shared with manual generation — set on the main screen.
class AlgoSheet extends StatefulWidget {
  const AlgoSheet({super.key, required this.clothes, this.showCount = true});
  final List<Cloth> clothes;
  // The manual builder places a single outfit on its canvas, so it hides the
  // "how many outfits" count slider (which only makes sense for AI batches).
  final bool showCount;

  @override
  State<AlgoSheet> createState() => AlgoSheetState();
}

class AlgoSheetState extends State<AlgoSheet> {
  late Future<List<AlgoMeta>> _future;
  AlgoMeta? _algo;
  int _minScore = 0;
  int _count = 1;
  String _weather = 'any'; // any | hot | cold
  final Set<String> _cats = {};
  String? _color;
  String? _brand;
  String? _tag;
  bool _fillGaps = false; // fill missing roles from any cloth

  /// pick-by-color / brand / tag define the outfit purely by that theme, so the
  /// weather + category presets don't apply to them.
  bool get _isPickTheme =>
      _algo != null && (_algo!.needs == 'color' ||
          _algo!.needs == 'brand' || _algo!.needs == 'tag');

  // A sensible ready-to-wear set per weather — one item per body slot. Picking
  // a weather pre-selects these so the user only has to tweak (e.g. add a cap).
  // Socks are included by default (untick if you don't want them).
  static const _hotDefaults = {'tshirt', 'shorts', 'shoes', 'socks'};
  static const _coldDefaults = {
    'hoodie', 'sweatshirt', // warm tops (sweat)
    'jeans', 'trousers', 'jogging', // warm bottoms (pantalon, jogging)
    'shoes', 'socks',
  };

  void _setWeather(String w) {
    setState(() {
      _weather = w;
      _cats.clear();
      if (w == 'hot') _cats.addAll(_hotDefaults);
      if (w == 'cold') _cats.addAll(_coldDefaults);
    });
  }

  /// Toggle a category. Unlike manual clothes picking, you CAN tick several
  /// conflicting types here (e.g. jeans + trousers): the algorithm keeps only
  /// one per slot when it builds the outfit, so these act as alternatives.
  void _toggleCat(String c) {
    setState(() {
      if (!_cats.remove(c)) _cats.add(c);
    });
  }

  static const _colors = [
    'Black', 'White', 'Grey', 'Beige', 'Brown', 'Blue',
    'Red', 'Green', 'Yellow', 'Orange', 'Purple', 'Pink',
  ];

  List<String> _brands = [];
  List<String> _tags = [];

  @override
  void initState() {
    super.initState();
    _future = outfitsServiceOf(context).listAlgos();
    _brands = _brandsFromClothes; // immediate from the snapshot…
    _tags = _tagsFromClothes;
    _loadLists(); // …then refresh from the server so they're never empty
  }

  Future<void> _loadLists() async {
    final svc = clothesServiceOf(context);
    try {
      final b = await svc.autocompleteBrands();
      if (mounted && b.isNotEmpty) setState(() => _brands = b);
    } catch (_) {}
    try {
      final t = await svc.autocompleteTags();
      if (mounted && t.isNotEmpty) setState(() => _tags = t);
    } catch (_) {}
  }

  List<String> get _tagsFromClothes {
    final set = <String>{};
    for (final c in widget.clothes) {
      set.addAll(c.customTags.map((t) => t.trim()).where((t) => t.isNotEmpty));
    }
    final list = set.toList()..sort();
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tr(context, 'algo.pick'),
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(tr(context, 'algo.guarantee'),
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 12),
              FutureBuilder<List<AlgoMeta>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (snap.hasError) {
                    return Text('${tr(context, 'algo.loadFailed')}: ${snap.error}',
                        style: const TextStyle(color: Colors.red));
                  }
                  final items = snap.data ?? const [];
                  if (_algo == null && items.isNotEmpty) {
                    _algo = items.first;
                  }
                  return RadioGroup<String>(
                    groupValue: _algo?.id,
                    onChanged: (v) => setState(() {
                      _algo = items.firstWhere((a) => a.id == v,
                          orElse: () => items.first);
                    }),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final a in items)
                          RadioListTile<String>(
                            value: a.id,
                            title: Text(trOr(context, 'algoName.${a.id}', a.label),
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                            subtitle:
                                Text(trOr(context, 'algoDesc.${a.id}', a.desc)),
                            dense: true,
                          ),
                      ],
                    ),
                  );
                },
              ),
              if (_algo?.needs == 'color') ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: _colors.map((c) => ChoiceChip(
                        label: Text(colorName(context, c)),
                        selected: _color == c,
                        onSelected: (_) => setState(() => _color = c),
                      )).toList(),
                ),
              ],
              if (_algo?.needs == 'brand') ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _brand,
                  decoration: InputDecoration(
                    labelText: tr(context, 'filter.brand'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: (_brands.isEmpty ? const [''] : _brands)
                      .map((b) => DropdownMenuItem(value: b, child: Text(b)))
                      .toList(),
                  onChanged: (v) => setState(() => _brand = v),
                ),
              ],
              if (_algo?.needs == 'tag') ...[
                const SizedBox(height: 8),
                if (_tags.isEmpty)
                  Text(tr(context, 'algo.noTags'),
                      style: TextStyle(color: Colors.grey, fontSize: 12))
                else
                  DropdownButtonFormField<String>(
                    initialValue: _tag,
                    decoration: InputDecoration(
                      labelText: tr(context, 'filter.tag'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: _tags
                        .map((t) =>
                            DropdownMenuItem(value: t, child: Text('#$t')))
                        .toList(),
                    onChanged: (v) => setState(() => _tag = v),
                  ),
              ],
              // Fill missing roles (e.g. shoes) from any cloth when the theme
              // (one brand, one colour…) can't cover them.
              CheckboxListTile(
                value: _fillGaps,
                onChanged: (v) => setState(() => _fillGaps = v ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                title: Text(tr(context, 'algo.fillGaps')),
                subtitle: Text(tr(context, 'algo.fillGapsHint'),
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ),
              // Weather + explicit types don't apply to a pick-by-* theme.
              if (!_isPickTheme) ...[
                const SizedBox(height: 16),
                Text(tr(context, 'algo.weather'),
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(tr(context, 'algo.weatherHint'),
                    style: const TextStyle(color: Colors.grey, fontSize: 12)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, children: [
                  ChoiceChip(
                    label: Text(tr(context, 'algo.any')),
                    selected: _weather == 'any',
                    onSelected: (_) => _setWeather('any'),
                  ),
                  ChoiceChip(
                    label: Text(tr(context, 'algo.hot')),
                    selected: _weather == 'hot',
                    onSelected: (_) => _setWeather('hot'),
                  ),
                  ChoiceChip(
                    label: Text(tr(context, 'algo.cold')),
                    selected: _weather == 'cold',
                    onSelected: (_) => _setWeather('cold'),
                  ),
                ]),
                const SizedBox(height: 12),
                Text(tr(context, 'algo.clothingTypes'),
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(tr(context, 'algo.clothingTypesHint'),
                    style: const TextStyle(color: Colors.grey, fontSize: 12)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  // Ordered head-to-toe so bottom-of-body types sit lower.
                  for (final c in [...kCategoryOptions]
                    ..sort((a, b) => bodyOrder(a).compareTo(bodyOrder(b))))
                    FilterChip(
                      label: Text(categoryName(context, c)),
                      selected: _cats.contains(c),
                      onSelected: (_) => _toggleCat(c),
                    ),
                ]),
              ],
              const SizedBox(height: 16),
              Text(tr(context, 'algo.minRating'),
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(tr(context, 'algo.minRatingHint'),
                  style: const TextStyle(color: Colors.grey, fontSize: 12)),
              Slider(
                value: _minScore.toDouble(),
                min: 0,
                max: 5,
                divisions: 5,
                label: _minScore == 0 ? 'No rating filter' : '$_minScore / 5',
                onChanged: (v) => setState(() => _minScore = v.round()),
              ),
              if (widget.showCount) ...[
                const SizedBox(height: 8),
                Text(tr(context, 'algo.count'),
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                const Text(
                    'You\'ll preview each selection, then confirm the ones you want rendered.',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
                Slider(
                  value: _count.toDouble(),
                  min: 1,
                  max: 6,
                  divisions: 5,
                  label: '$_count ${_count == 1 ? "outfit" : "outfits"}',
                  onChanged: (v) => setState(() => _count = v.round()),
                ),
              ],
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed: _algo == null
                      ? null
                      : () {
                          final a = _algo!;
                          if (a.needs == 'color' && (_color == null || _color!.isEmpty)) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(tr(context, 'algo.pickColorFirst'))));
                            return;
                          }
                          if (a.needs == 'brand' && (_brand == null || _brand!.isEmpty)) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(tr(context, 'algo.pickBrandFirst'))));
                            return;
                          }
                          if (a.needs == 'tag' && (_tag == null || _tag!.isEmpty)) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(tr(context, 'algo.pickTagFirst'))));
                            return;
                          }
                          Navigator.pop(
                            context,
                            AlgoPick(
                              algo: a.id,
                              minScore: _minScore,
                              color: _color ?? '',
                              brand: _brand ?? '',
                              tag: _tag ?? '',
                              count: _count,
                              // A pick-by-* theme defines the whole outfit, so
                              // the weather + category presets don't apply.
                              weather: _isPickTheme ? 'any' : _weather,
                              categories:
                                  _isPickTheme ? const [] : _cats.toList(),
                              fillGaps: _fillGaps,
                            ),
                          );
                        },
                  icon: const Icon(Icons.auto_awesome),
                  label: Text('${tr(context, 'algo.preview')} $_count '
                      '${trPlural(context, 'algo.outfit', _count)}'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<String> get _brandsFromClothes {
    final set = <String>{};
    for (final c in widget.clothes) {
      if (c.brand.trim().isNotEmpty) set.add(c.brand.trim());
    }
    final list = set.toList()..sort();
    return list;
  }
}
