import 'package:flutter/material.dart';

import '../../app.dart';
import '../../design/ds.dart';
import '../../l10n/app_text.dart';
import '../../models/cloth.dart';
import '../../models/plan.dart';
import '../../models/weather.dart';
import '../../services/outfits_service.dart';
import '../settings/weather_location_screen.dart';

/// How the week is drawn.
///
/// Deliberately a different sheet from the one behind a single outfit, for one
/// reason: a week takes a *set* of algorithms, not one. Everything else — the
/// weather chips, the clothing types, the rating filter, gap filling — is the
/// same question with the same words, so it looks and reads the same.
class WeekOptionsSheet extends StatefulWidget {
  const WeekOptionsSheet({super.key, required this.clothes, this.initial});

  final List<Cloth> clothes;
  final PlanOptions? initial;

  @override
  State<WeekOptionsSheet> createState() => _WeekOptionsSheetState();
}

class _WeekOptionsSheetState extends State<WeekOptionsSheet> {
  late Future<List<AlgoMeta>> _algosFuture;

  /// The mix, in the order the user built it — which is the order the days use.
  late List<PlanAlgoChoice> _mix;
  late String _weather;
  late Set<String> _cats;
  late int _minScore;
  late bool _fillGaps;
  late bool _allowRepeatTheme;

  DayWeather? _forecast;
  bool _forecastLoading = false;

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
    final initial = widget.initial ?? PlanOptions.defaults();
    _mix = [...initial.algos];
    _weather = initial.weather;
    _cats = {...initial.categories};
    _minScore = initial.minScore;
    _fillGaps = initial.fillGaps;
    _allowRepeatTheme = initial.allowRepeatTheme;
    _algosFuture = outfitsServiceOf(context).listAlgos();
    _brands = _brandsFromClothes;
    _tags = _tagsFromClothes;
    _loadLists();
    if (_weather == 'auto') _loadForecast();
  }

  List<String> get _brandsFromClothes {
    final set = <String>{
      for (final c in widget.clothes)
        if (c.brand.trim().isNotEmpty) c.brand.trim(),
    };
    return set.toList()..sort();
  }

  List<String> get _tagsFromClothes {
    final set = <String>{
      for (final c in widget.clothes)
        for (final t in c.customTags)
          if (t.trim().isNotEmpty) t.trim(),
    };
    return set.toList()..sort();
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

  Future<void> _loadForecast() async {
    final svc = weatherServiceOf(context);
    setState(() => _forecastLoading = true);
    try {
      final got = await svc.forecast();
      if (!mounted) return;
      setState(() {
        _forecast = got;
        _forecastLoading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _forecast = null;
          _forecastLoading = false;
        });
      }
    }
  }

  bool _isInMix(String algo) => _mix.any((e) => e.algo == algo);

  /// Tapping an algorithm adds it to the mix — or, for a pick-by-* one, asks
  /// for its value first. An entry with no value would silently do nothing on
  /// the server, so it is never created.
  Future<void> _toggleAlgo(AlgoMeta meta) async {
    if (_isInMix(meta.id)) {
      setState(() => _mix.removeWhere((e) => e.algo == meta.id));
      return;
    }
    if (!algoNeedsValue(meta.needs)) {
      setState(() => _mix.add(PlanAlgoChoice(algo: meta.id)));
      return;
    }
    final value = await _askValue(meta);
    if (value == null || value.isEmpty || !mounted) return;
    setState(
      () => _mix.add(
        PlanAlgoChoice(
          algo: meta.id,
          color: meta.needs == 'color' ? value : '',
          brand: meta.needs == 'brand' ? value : '',
          tag: meta.needs == 'tag' ? value : '',
        ),
      ),
    );
  }

  Future<String?> _askValue(AlgoMeta meta) {
    // Explicit per kind — the old `_ => _tags` default is what turned an
    // unrecognised `needs` into "Which tag?".
    final options = switch (meta.needs) {
      'color' => _colors,
      'brand' => _brands,
      'tag' => _tags,
      _ => const <String>[],
    };
    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(switch (meta.needs) {
          'color' => tr(ctx, 'week.pickColor'),
          'brand' => tr(ctx, 'week.pickBrand'),
          _ => tr(ctx, 'week.pickTag'),
        }),
        children: [
          if (options.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(tr(ctx, 'week.noValues')),
            ),
          for (final o in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, o),
              child: Text(meta.needs == 'color' ? colorName(ctx, o) : o),
            ),
        ],
      ),
    );
  }

  String _chipLabel(PlanAlgoChoice e, List<AlgoMeta> metas) {
    final meta = metas.where((m) => m.id == e.algo).firstOrNull;
    final name = trOr(context, 'algoName.${e.algo}', meta?.label ?? e.algo);
    final value = e.value;
    if (value.isEmpty) return name;
    return '$name · ${e.color.isNotEmpty ? colorName(context, value) : value}';
  }

  void _setWeather(String w) {
    setState(() => _weather = w);
    if (w == 'auto') _loadForecast();
  }

  PlanOptions get _result => PlanOptions(
    algos: _mix,
    weather: _weather,
    categories: _cats.toList(),
    minScore: _minScore,
    fillGaps: _fillGaps,
    allowRepeatTheme: _allowRepeatTheme,
  );

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final muted = ds.typo.label.copyWith(color: ds.colors.textMuted);
    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (context, controller) => Column(
          children: [
            Expanded(
              child: ListView(
                controller: controller,
                padding: EdgeInsets.fromLTRB(
                  ds.space.gutter,
                  0,
                  ds.space.gutter,
                  ds.space.s,
                ),
                children: [
                  Text(
                    tr(context, 'week.title').toUpperCase(),
                    style: ds.typo.headline,
                  ),
                  SizedBox(height: ds.space.xs / 2),
                  Text(tr(context, 'week.subtitle'), style: muted),
                  DsSectionTitle(
                    tr(context, 'week.algos'),
                    hint: tr(context, 'week.algosHint'),
                  ),
                  _algoPicker(),
                  if (_mix.length > 1)
                    Padding(
                      padding: EdgeInsets.only(top: ds.space.xs),
                      child: Text(
                        tr(context, 'week.rotationHint', {
                          'count': '${_mix.length}',
                        }),
                        style: ds.typo.label.copyWith(
                          color: ds.colors.accentText,
                        ),
                      ),
                    ),
                  DsSectionTitle(tr(context, 'algo.weather')),
                  _weatherChips(),
                  DsSectionTitle(
                    tr(context, 'algo.clothingTypes'),
                    hint: tr(context, 'algo.clothingTypesHint'),
                  ),
                  Wrap(
                    spacing: ds.space.xs,
                    runSpacing: ds.space.xs,
                    children: [
                      for (final c in [
                        ...kCategoryOptions,
                      ]..sort((a, b) => bodyOrder(a).compareTo(bodyOrder(b))))
                        DsChip(
                          label: categoryName(context, c),
                          selected: _cats.contains(c),
                          onTap: () => setState(
                            () => _cats.contains(c)
                                ? _cats.remove(c)
                                : _cats.add(c),
                          ),
                        ),
                    ],
                  ),
                  DsSectionTitle(tr(context, 'algo.minRating')),
                  DsSegment<int>(
                    options: [
                      (0, tr(context, 'algo.noRatingFilter')),
                      for (var n = 1; n <= 5; n++) (n, '$n+'),
                    ],
                    value: _minScore,
                    onChanged: (v) => setState(() => _minScore = v),
                  ),
                  SizedBox(height: ds.space.s),
                  CheckboxListTile(
                    value: _fillGaps,
                    onChanged: (v) => setState(() => _fillGaps = v ?? false),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    title: Text(
                      tr(context, 'algo.fillGaps'),
                      style: ds.typo.body,
                    ),
                    subtitle: Text(
                      tr(context, 'algo.fillGapsHint'),
                      style: muted,
                    ),
                  ),
                  CheckboxListTile(
                    value: _allowRepeatTheme,
                    onChanged: (v) =>
                        setState(() => _allowRepeatTheme = v ?? false),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    title: Text(
                      tr(context, 'week.repeatTheme'),
                      style: ds.typo.body,
                    ),
                    subtitle: Text(
                      tr(context, 'week.repeatThemeHint'),
                      style: muted,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                ds.space.gutter,
                ds.space.xs,
                ds.space.gutter,
                ds.space.m,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: DsButton(
                      label: tr(context, 'common.cancel'),
                      kind: DsButtonKind.secondary,
                      expand: true,
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                  SizedBox(width: ds.space.s),
                  Expanded(
                    flex: 2,
                    child: DsButton(
                      // An empty mix would be a week with no rule at all; the
                      // button says why it is off rather than failing on tap.
                      label: _mix.isEmpty
                          ? tr(context, 'week.pickAtLeastOne')
                          : tr(context, 'week.apply'),
                      expand: true,
                      onPressed: _mix.isEmpty
                          ? null
                          : () => Navigator.pop(context, _result),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _algoPicker() {
    final ds = context.ds;
    return FutureBuilder<List<AlgoMeta>>(
      future: _algosFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return Padding(
            padding: EdgeInsets.all(ds.space.m),
            child: Center(
              child: CircularProgressIndicator(color: ds.colors.accent),
            ),
          );
        }
        final metas = snap.data ?? const <AlgoMeta>[];
        if (metas.isEmpty) {
          return Text(
            tr(context, 'algo.loadFailed'),
            style: ds.typo.label.copyWith(color: ds.colors.danger),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // What is in the mix, in the order the days will use it. Removable
            // one by one, because "start over" is not the usual correction.
            if (_mix.isNotEmpty) ...[
              for (var i = 0; i < _mix.length; i++)
                Row(
                  children: [
                    SizedBox(
                      width: 28,
                      child: Text(
                        '${i + 1}'.padLeft(2, '0'),
                        style: ds.typo.mono.copyWith(
                          color: ds.colors.accentText,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        _chipLabel(_mix[i], metas),
                        style: ds.typo.body,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: tr(context, 'agenda.remove'),
                      onPressed: () => setState(() => _mix.removeAt(i)),
                    ),
                  ],
                ),
              SizedBox(height: ds.space.s),
            ],
            Wrap(
              spacing: ds.space.xs,
              runSpacing: ds.space.xs,
              children: [
                for (final m in metas)
                  DsChip(
                    label: trOr(context, 'algoName.${m.id}', m.label),
                    selected: _isInMix(m.id),
                    onTap: () => _toggleAlgo(m),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _weatherChips() {
    final ds = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wb_sunny_outlined, size: 16),
              label: tr(context, 'algo.autoWeather'),
              selected: _weather == 'auto',
              onTap: () => _setWeather('auto'),
            ),
          ],
        ),
        if (_weather == 'auto') _forecastLine(),
      ],
    );
  }

  /// In a week, 'auto' means a forecast PER DAY — so this line says that
  /// rather than quoting today's temperature as if it applied to all seven.
  Widget _forecastLine() {
    final ds = context.ds;
    final muted = ds.typo.label.copyWith(color: ds.colors.textMuted);
    if (_forecastLoading) {
      return Padding(
        padding: EdgeInsets.only(top: ds.space.xs),
        child: Text(tr(context, 'algo.autoLoading'), style: muted),
      );
    }
    final f = _forecast;
    if (f == null || !f.available) {
      return Padding(
        padding: EdgeInsets.only(top: ds.space.xs),
        child: Align(
          alignment: Alignment.centerLeft,
          child: DsButton(
            label: tr(context, 'algo.autoNeedsPlace'),
            icon: Icons.place_outlined,
            kind: DsButtonKind.secondary,
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
    return Padding(
      padding: EdgeInsets.only(top: ds.space.xs),
      child: Text(
        tr(context, 'week.autoPerDay', {'place': f.place}),
        style: muted,
      ),
    );
  }
}
