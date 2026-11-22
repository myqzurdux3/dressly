import 'package:flutter/material.dart';

import '../../app.dart';
import '../../design/ds.dart';
import '../../l10n/app_text.dart';
import '../../models/cloth.dart';
import '../../models/weather.dart';
import '../../services/outfits_service.dart';
import '../settings/weather_location_screen.dart';

class AlgoPick {
  final String algo;
  final int minScore;
  final String color;
  final String brand;
  final String tag;
  final int count;

  /// 'any' | 'hot' | 'cold' | 'auto'. 'auto' lets the server read the
  /// forecast; it resolves to 'any' when there is no location or no forecast.
  final String weather;
  final List<String>
  categories; // explicit category choices (overrides weather)
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
  String _weather = 'any'; // any | hot | cold | auto
  /// Today's forecast, fetched only once the user asks for 'auto' — nobody
  /// else's screen should pay a network round trip for a feature they are not
  /// using.
  DayWeather? _forecast;
  bool _forecastLoading = false;
  final Set<String> _cats = {};
  String? _color;
  String? _brand;
  String? _tag;
  bool _fillGaps = false; // fill missing roles from any cloth

  /// pick-by-color / brand / tag define the outfit purely by that theme, so the
  /// weather + category presets don't apply to them.
  bool get _isPickTheme =>
      _algo != null &&
      (_algo!.needs == 'color' ||
          _algo!.needs == 'brand' ||
          _algo!.needs == 'tag');

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
    if (w == 'auto') _loadForecast();
  }

  /// Ask what today looks like, then pre-tick the same categories the matching
  /// manual choice would have. The user sees the result of the decision, not
  /// just the word "auto" — and can still untick anything.
  Future<void> _loadForecast() async {
    final svc = weatherServiceOf(context);
    setState(() => _forecastLoading = true);
    try {
      final got = await svc.forecast();
      if (!mounted) return;
      setState(() {
        _forecast = got;
        _forecastLoading = false;
        if (_weather != 'auto') return; // the user moved on while it loaded
        _cats.clear();
        if (got.isHot) _cats.addAll(_hotDefaults);
        if (got.isCold) _cats.addAll(_coldDefaults);
      });
    } catch (_) {
      if (!mounted) return;
      // No forecast is not an error worth a dialog: the server resolves 'auto'
      // to 'any' and the outfit still gets generated.
      setState(() {
        _forecast = null;
        _forecastLoading = false;
      });
    }
  }

  /// What 'auto' decided, in one line: the temperature and which wardrobe it
  /// picked — or, when there is nothing to go on, the way to fix that.
  Widget _forecastLine() {
    final ds = context.ds;
    final muted = ds.typo.label.copyWith(color: ds.colors.textMuted);
    if (_forecastLoading) {
      return Padding(
        padding: EdgeInsets.only(top: ds.space.s),
        child: Text(tr(context, 'algo.autoLoading'), style: muted),
      );
    }
    final f = _forecast;
    if (f == null || !f.available) {
      // No location set is the likely reason, and it is one tap to fix, so the
      // line is a button rather than a complaint.
      return Padding(
        padding: EdgeInsets.only(top: ds.space.s),
        child: Align(
          alignment: Alignment.centerLeft,
          child: DsButton(
            icon: Icons.place_outlined,
            kind: DsButtonKind.secondary,
            label: tr(context, 'algo.autoNeedsPlace'),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const WeatherLocationScreen(),
                ),
              );
              if (mounted && _weather == 'auto') await _loadForecast();
            },
          ),
        ),
      );
    }
    final label = f.isHot
        ? tr(context, 'algo.hot')
        : f.isCold
        ? tr(context, 'algo.cold')
        : tr(context, 'algo.any');
    return Padding(
      padding: EdgeInsets.only(top: ds.space.s),
      child: Row(
        children: [
          Icon(
            f.isHot ? Icons.wb_sunny_outlined : Icons.ac_unit,
            size: 16,
            color: ds.colors.accent,
          ),
          SizedBox(width: ds.space.xs),
          Expanded(
            child: Text(
              tr(context, 'algo.autoResult', {
                'place': f.place,
                'temp': f.shortTemp,
                'mode': label.toLowerCase(),
              }),
              style: muted,
            ),
          ),
        ],
      ),
    );
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
    'Black',
    'White',
    'Grey',
    'Beige',
    'Brown',
    'Blue',
    'Red',
    'Green',
    'Yellow',
    'Orange',
    'Purple',
    'Pink',
  ];

  List<String> _brands = [];
  List<String> _tags = [];

  @override
  void initState() {
    super.initState();
    _future = outfitsServiceOf(context).listAlgos().then((items) {
      // Picked here, with setState, so the preview button below the list is
      // rebuilt enabled: picking it inside the list's builder left the button
      // built (disabled) before the default existed.
      if (mounted && _algo == null && items.isNotEmpty) {
        setState(() => _algo = items.first);
      }
      return items;
    });
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
    final ds = context.ds;
    final c = ds.colors;
    final muted = ds.typo.label.copyWith(color: c.textMuted);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            ds.space.gutter,
            ds.space.s,
            ds.space.gutter,
            ds.space.l,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tr(context, 'algo.pick').toUpperCase(),
                style: ds.typo.headline,
              ),
              SizedBox(height: ds.space.xs),
              Text(tr(context, 'algo.guarantee'), style: muted),
              SizedBox(height: ds.space.s),
              FutureBuilder<List<AlgoMeta>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return Padding(
                      padding: EdgeInsets.all(ds.space.m),
                      child: Center(
                        child: CircularProgressIndicator(color: c.accent),
                      ),
                    );
                  }
                  if (snap.hasError) {
                    return Text(
                      '${tr(context, 'algo.loadFailed')}: ${snap.error}',
                      style: ds.typo.label.copyWith(color: c.danger),
                    );
                  }
                  final items = snap.data ?? const [];
                  if (_algo == null && items.isNotEmpty) {
                    _algo = items.first;
                  }
                  return RadioGroup<String>(
                    groupValue: _algo?.id,
                    onChanged: (v) => setState(() {
                      _algo = items.firstWhere(
                        (a) => a.id == v,
                        orElse: () => items.first,
                      );
                    }),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final a in items)
                          RadioListTile<String>(
                            value: a.id,
                            contentPadding: EdgeInsets.zero,
                            activeColor: c.accent,
                            title: Text(
                              trOr(context, 'algoName.${a.id}', a.label),
                              style: ds.typo.bodyStrong,
                            ),
                            subtitle: Text(
                              trOr(context, 'algoDesc.${a.id}', a.desc),
                              style: muted,
                            ),
                            dense: true,
                          ),
                      ],
                    ),
                  );
                },
              ),
              if (_algo?.needs == 'color') ...[
                SizedBox(height: ds.space.s),
                Wrap(
                  spacing: ds.space.xs,
                  runSpacing: ds.space.xs,
                  children: [
                    for (final col in _colors)
                      DsChip(
                        label: colorName(context, col),
                        leading: CircleAvatar(
                          radius: 7,
                          backgroundColor: garmentTone(
                            col,
                            Theme.of(context).brightness,
                          ).fill,
                        ),
                        selected: _color == col,
                        onTap: () => setState(() => _color = col),
                      ),
                  ],
                ),
              ],
              if (_algo?.needs == 'brand') ...[
                SizedBox(height: ds.space.s),
                DropdownButtonFormField<String>(
                  initialValue: _brand,
                  decoration: InputDecoration(
                    labelText: tr(context, 'filter.brand'),
                  ),
                  items: (_brands.isEmpty ? const [''] : _brands)
                      .map((b) => DropdownMenuItem(value: b, child: Text(b)))
                      .toList(),
                  onChanged: (v) => setState(() => _brand = v),
                ),
              ],
              if (_algo?.needs == 'tag') ...[
                SizedBox(height: ds.space.s),
                if (_tags.isEmpty)
                  Text(tr(context, 'algo.noTags'), style: muted)
                else
                  DropdownButtonFormField<String>(
                    initialValue: _tag,
                    decoration: InputDecoration(
                      labelText: tr(context, 'filter.tag'),
                    ),
                    items: _tags
                        .map(
                          (t) => DropdownMenuItem(value: t, child: Text('#$t')),
                        )
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
                title: Text(tr(context, 'algo.fillGaps'), style: ds.typo.body),
                subtitle: Text(tr(context, 'algo.fillGapsHint'), style: muted),
              ),
              // Weather + explicit types don't apply to a pick-by-* theme.
              if (!_isPickTheme) ...[
                DsSectionTitle(
                  tr(context, 'algo.weather'),
                  hint: tr(context, 'algo.weatherHint'),
                ),
                Wrap(
                  spacing: ds.space.xs,
                  runSpacing: ds.space.xs,
                  children: [
                    for (final (w, key) in const [
                      ('any', 'algo.any'),
                      ('hot', 'algo.hot'),
                      ('cold', 'algo.cold'),
                    ])
                      DsChip(
                        label: tr(context, key),
                        selected: _weather == w,
                        onTap: () => _setWeather(w),
                      ),
                    DsChip(
                      leading: _forecastLoading
                          ? SizedBox.square(
                              dimension: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: c.accent,
                              ),
                            )
                          : const Icon(Icons.wb_sunny_outlined, size: 16),
                      label: tr(context, 'algo.autoWeather'),
                      selected: _weather == 'auto',
                      onTap: () => _setWeather('auto'),
                    ),
                  ],
                ),
                if (_weather == 'auto') _forecastLine(),
                DsSectionTitle(
                  tr(context, 'algo.clothingTypes'),
                  hint: tr(context, 'algo.clothingTypesHint'),
                ),
                Wrap(
                  spacing: ds.space.xs,
                  runSpacing: ds.space.xs,
                  children: [
                    // Ordered head-to-toe so bottom-of-body types sit lower.
                    for (final cat in [
                      ...kCategoryOptions,
                    ]..sort((a, b) => bodyOrder(a).compareTo(bodyOrder(b))))
                      DsChip(
                        label: categoryName(context, cat),
                        selected: _cats.contains(cat),
                        onTap: () => _toggleCat(cat),
                      ),
                  ],
                ),
              ],
              DsSectionTitle(
                tr(context, 'algo.minRating'),
                hint: tr(context, 'algo.minRatingHint'),
              ),
              DsSegment<int>(
                options: [
                  (0, tr(context, 'algo.noRatingFilter')),
                  for (var n = 1; n <= 5; n++) (n, '$n+'),
                ],
                value: _minScore,
                onChanged: (v) => setState(() => _minScore = v),
              ),
              if (widget.showCount) ...[
                DsSectionTitle(
                  tr(context, 'algo.count'),
                  hint: tr(context, 'algo.countHint'),
                ),
                DsSegment<int>(
                  options: [for (var n = 1; n <= 6; n++) (n, '$n')],
                  value: _count,
                  onChanged: (v) => setState(() => _count = v),
                ),
              ],
              SizedBox(height: ds.space.l),
              DsButton(
                expand: true,
                icon: Icons.auto_awesome,
                label:
                    '${tr(context, 'algo.preview')} $_count '
                    '${trPlural(context, 'algo.outfit', _count)}',
                onPressed: _algo == null
                    ? null
                    : () {
                        final a = _algo!;
                        if (a.needs == 'color' &&
                            (_color == null || _color!.isEmpty)) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(tr(context, 'algo.pickColorFirst')),
                            ),
                          );
                          return;
                        }
                        if (a.needs == 'brand' &&
                            (_brand == null || _brand!.isEmpty)) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(tr(context, 'algo.pickBrandFirst')),
                            ),
                          );
                          return;
                        }
                        if (a.needs == 'tag' &&
                            (_tag == null || _tag!.isEmpty)) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(tr(context, 'algo.pickTagFirst')),
                            ),
                          );
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
                            categories: _isPickTheme
                                ? const []
                                : _cats.toList(),
                            fillGaps: _fillGaps,
                          ),
                        );
                      },
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
