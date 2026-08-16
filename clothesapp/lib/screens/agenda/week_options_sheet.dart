import 'package:flutter/material.dart';

import '../../app.dart';
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
    'Black', 'White', 'Grey', 'Beige', 'Brown', 'Blue',
    'Red', 'Green', 'Yellow', 'Orange', 'Purple', 'Pink',
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
        if (c.brand.trim().isNotEmpty) c.brand.trim()
    };
    return set.toList()..sort();
  }

  List<String> get _tagsFromClothes {
    final set = <String>{
      for (final c in widget.clothes)
        for (final t in c.customTags)
          if (t.trim().isNotEmpty) t.trim()
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
    setState(() => _mix.add(PlanAlgoChoice(
          algo: meta.id,
          color: meta.needs == 'color' ? value : '',
          brand: meta.needs == 'brand' ? value : '',
          tag: meta.needs == 'tag' ? value : '',
        )));
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
    final theme = Theme.of(context);
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
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                children: [
                  Text(tr(context, 'week.title'),
                      style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(tr(context, 'week.subtitle'),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 16),
                  _sectionTitle(tr(context, 'week.algos')),
                  Text(tr(context, 'week.algosHint'),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  _algoPicker(),
                  const SizedBox(height: 8),
                  if (_mix.length > 1)
                    Text(tr(context, 'week.rotationHint', {
                      'count': '${_mix.length}',
                    }),
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary)),
                  const Divider(height: 32),
                  _sectionTitle(tr(context, 'algo.weather')),
                  const SizedBox(height: 6),
                  _weatherChips(),
                  const SizedBox(height: 16),
                  _sectionTitle(tr(context, 'algo.clothingTypes')),
                  Text(tr(context, 'algo.clothingTypesHint'),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final c in [...kCategoryOptions]
                      ..sort((a, b) => bodyOrder(a).compareTo(bodyOrder(b))))
                      FilterChip(
                        label: Text(categoryName(context, c)),
                        selected: _cats.contains(c),
                        onSelected: (_) => setState(
                            () => _cats.contains(c) ? _cats.remove(c) : _cats.add(c)),
                      ),
                  ]),
                  const SizedBox(height: 16),
                  _sectionTitle(tr(context, 'algo.minRating')),
                  Slider(
                    value: _minScore.toDouble(),
                    min: 0,
                    max: 5,
                    divisions: 5,
                    label: _minScore == 0
                        ? tr(context, 'algo.noRatingFilter')
                        : '$_minScore / 5',
                    onChanged: (v) => setState(() => _minScore = v.round()),
                  ),
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
                  CheckboxListTile(
                    value: _allowRepeatTheme,
                    onChanged: (v) =>
                        setState(() => _allowRepeatTheme = v ?? false),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    title: Text(tr(context, 'week.repeatTheme')),
                    subtitle: Text(tr(context, 'week.repeatThemeHint'),
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(tr(context, 'common.cancel')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    // An empty mix would be a week with no rule at all; the
                    // button says why it is off rather than failing on tap.
                    onPressed: _mix.isEmpty
                        ? null
                        : () => Navigator.pop(context, _result),
                    child: Text(_mix.isEmpty
                        ? tr(context, 'week.pickAtLeastOne')
                        : tr(context, 'week.apply')),
                  ),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String t) =>
      Text(t, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold));

  Widget _algoPicker() {
    return FutureBuilder<List<AlgoMeta>>(
      future: _algosFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final metas = snap.data ?? const <AlgoMeta>[];
        if (metas.isEmpty) {
          return Text(tr(context, 'algo.loadFailed'),
              style: const TextStyle(color: Colors.red));
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // What is in the mix, in the order the days will use it. Removable
          // one by one, because "start over" is not the usual correction.
          if (_mix.isNotEmpty) ...[
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (var i = 0; i < _mix.length; i++)
                InputChip(
                  avatar: CircleAvatar(
                    radius: 10,
                    child: Text('${i + 1}',
                        style: const TextStyle(fontSize: 10)),
                  ),
                  label: Text(_chipLabel(_mix[i], metas)),
                  onDeleted: () => setState(() => _mix.removeAt(i)),
                ),
            ]),
            const SizedBox(height: 10),
          ],
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final m in metas)
              FilterChip(
                label: Text(trOr(context, 'algoName.${m.id}', m.label)),
                selected: _isInMix(m.id),
                onSelected: (_) => _toggleAlgo(m),
              ),
          ]),
        ]);
      },
    );
  }

  Widget _weatherChips() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
        ChoiceChip(
          avatar: _forecastLoading
              ? const SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.wb_sunny_outlined, size: 16),
          label: Text(tr(context, 'algo.autoWeather')),
          selected: _weather == 'auto',
          onSelected: (_) => _setWeather('auto'),
        ),
      ]),
      if (_weather == 'auto') _forecastLine(),
    ]);
  }

  /// In a week, 'auto' means a forecast PER DAY — so this line says that
  /// rather than quoting today's temperature as if it applied to all seven.
  Widget _forecastLine() {
    final theme = Theme.of(context);
    if (_forecastLoading) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(tr(context, 'algo.autoLoading'),
            style: TextStyle(
                fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
      );
    }
    final f = _forecast;
    if (f == null || !f.available) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.place_outlined, size: 18),
            label: Text(tr(context, 'algo.autoNeedsPlace')),
            onPressed: () async {
              await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const WeatherLocationScreen()));
              if (mounted && _weather == 'auto') await _loadForecast();
            },
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        tr(context, 'week.autoPerDay', {'place': f.place}),
        style: TextStyle(
            fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}
