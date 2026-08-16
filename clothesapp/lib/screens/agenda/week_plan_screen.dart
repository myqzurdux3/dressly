import 'package:flutter/material.dart';

import '../../app.dart';
import '../../l10n/app_text.dart';
import '../../models/cloth.dart';
import '../../models/plan.dart';
import '../../widgets/app_image.dart';
import 'week_options_sheet.dart';

/// A week of outfits, one card per day.
///
/// Nothing is written until "save" — the screen holds a proposal. Pin the days
/// you like, redraw the rest, save once. No image is generated here: a plan is
/// the clothes, and rendering seven outfits would be seven paid calls for a
/// week you may still change.
class WeekPlanScreen extends StatefulWidget {
  const WeekPlanScreen({super.key});

  @override
  State<WeekPlanScreen> createState() => _WeekPlanScreenState();
}

class _WeekPlanScreenState extends State<WeekPlanScreen> {
  WeekPlan? _plan;
  Object? _error;
  bool _loading = true;
  bool _saving = false;

  /// How the week is drawn. Kept across redraws so pressing "redraw" repeats
  /// the same rules with different clothes, which is what the button promises.
  PlanOptions _options = PlanOptions.defaults();
  List<Cloth> _clothes = const [];

  /// Days the user pinned. Kept here rather than on the model so a redraw —
  /// which replaces every PlanDay — cannot lose them.
  final Set<String> _locked = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _draw();
      _loadClothes();
    });
  }

  Map<String, List<int>> get _keep {
    final plan = _plan;
    if (plan == null) return const {};
    return {
      for (final d in plan.days)
        if (_locked.contains(d.day) && d.clothIds.isNotEmpty)
          d.day: d.clothIds,
    };
  }

  /// The wardrobe, for the options sheet's brand/tag/colour lists. Loaded once
  /// and quietly: the planner is usable without it (the server also serves the
  /// autocomplete lists), so a failure here is not worth an error state.
  Future<void> _loadClothes() async {
    try {
      final clothes = await clothesServiceOf(context).list();
      if (mounted) setState(() => _clothes = clothes);
    } catch (_) {}
  }

  Future<void> _openOptions() async {
    final picked = await showModalBottomSheet<PlanOptions>(
      context: context,
      isScrollControlled: true,
      builder: (_) => WeekOptionsSheet(clothes: _clothes, initial: _options),
    );
    if (picked == null || !mounted) return;
    setState(() => _options = picked);
    await _draw();
  }

  Future<void> _draw() async {
    final svc = planServiceOf(context);
    final keep = _keep;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final plan = await svc.preview(keep: keep, options: _options);
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    final plan = _plan;
    if (plan == null || plan.isEmpty) return;
    final svc = planServiceOf(context);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _saving = true);
    try {
      final result = await svc.apply(plan.applicable);
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(
        content: Text(result.skipped.isEmpty
            ? tr(context, 'plan.saved', {'count': '${result.created}'})
            : tr(context, 'plan.savedWithSkips', {
                'count': '${result.created}',
                'skipped': '${result.skipped.length}',
              })),
      ));
      navigator.pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  void _toggleLock(PlanDay day) {
    setState(() {
      if (!_locked.remove(day.day)) _locked.add(day.day);
    });
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final canSave = plan != null && !plan.isEmpty && !_saving && !_loading;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'plan.title')),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: tr(context, 'week.title'),
            onPressed: _loading || _saving ? null : _openOptions,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: tr(context, 'plan.redraw'),
            onPressed: _loading || _saving ? null : _draw,
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            onPressed: canSave ? _save : null,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.event_available),
            label: Text(tr(context, 'plan.save')),
          ),
        ),
      ),
      body: _body(),
    );
  }

  /// The rules the current week was drawn from, in one tappable line. Without
  /// it the options live behind an icon and the screen cannot say why it
  /// proposed what it proposed.
  Widget _optionsBar() {
    final theme = Theme.of(context);
    final names = [
      for (final a in _options.algos)
        trOr(context, 'algoName.${a.algo}', a.algo) +
            (a.value.isEmpty ? '' : ' · ${a.value}')
    ].join(' + ');
    final weather = switch (_options.weather) {
      'hot' => tr(context, 'algo.hot'),
      'cold' => tr(context, 'algo.cold'),
      'auto' => tr(context, 'algo.autoWeather'),
      _ => tr(context, 'algo.any'),
    };
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.tune),
        title: Text(names.isEmpty ? tr(context, 'week.pickAtLeastOne') : names,
            maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            weather,
            if (_options.categories.isNotEmpty)
              tr(context, 'week.typesCount',
                  {'count': '${_options.categories.length}'}),
            if (_options.minScore > 0) '${_options.minScore}★+',
            if (_options.allowRepeatTheme) tr(context, 'week.repeatTheme'),
          ].join(' · '),
          style: theme.textTheme.bodySmall,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: _loading || _saving ? null : _openOptions,
      ),
    );
  }

  Widget _body() {
    if (_loading && _plan == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('${tr(context, 'plan.loadError')}: $_error',
              textAlign: TextAlign.center),
        ),
      );
    }
    final plan = _plan!;
    if (plan.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(tr(context, 'plan.nothingToPlan'),
              textAlign: TextAlign.center),
        ),
      );
    }
    return Stack(children: [
      ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
        children: [
          _optionsBar(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Text(tr(context, 'plan.hint'),
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          for (final day in plan.days)
            _DayCard(
              day: day,
              locked: _locked.contains(day.day),
              onToggleLock: () => _toggleLock(day),
            ),
        ],
      ),
      // A redraw keeps the old week on screen underneath, so the page does not
      // blank out and jump back to the top on every tap.
      if (_loading)
        const Positioned(
          top: 0, left: 0, right: 0,
          child: LinearProgressIndicator(minHeight: 2),
        ),
    ]);
  }
}

class _DayCard extends StatelessWidget {
  const _DayCard({
    required this.day,
    required this.locked,
    required this.onToggleLock,
  });

  final PlanDay day;
  final bool locked;
  final VoidCallback onToggleLock;

  String _dayLabel(BuildContext context) {
    final parsed = DateTime.tryParse(day.day);
    if (parsed == null) return day.day;
    // The platform's own formatter: localised weekday and month names for free,
    // instead of an English list hard-coded in the app.
    final label = MaterialLocalizations.of(context).formatMediumDate(parsed);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = DateTime(parsed.year, parsed.month, parsed.day)
        .difference(today)
        .inDays;
    if (diff == 0) return '${tr(context, 'plan.today')} · $label';
    if (diff == 1) return '${tr(context, 'plan.tomorrow')} · $label';
    return label;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      shape: locked
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: theme.colorScheme.primary, width: 1.5))
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(_dayLabel(context),
                      style: theme.textTheme.titleSmall),
                ),
                if (day.weatherAvailable) ...[
                  Icon(
                      day.weatherMode == 'hot'
                          ? Icons.wb_sunny_outlined
                          : Icons.ac_unit,
                      size: 16,
                      color: theme.colorScheme.primary),
                  const SizedBox(width: 4),
                  Text(day.shortTemp, style: theme.textTheme.bodySmall),
                ],
                IconButton(
                  icon: Icon(locked ? Icons.lock : Icons.lock_open_outlined),
                  color: locked ? theme.colorScheme.primary : null,
                  tooltip: locked
                      ? tr(context, 'plan.unlockDay')
                      : tr(context, 'plan.lockDay'),
                  onPressed: onToggleLock,
                ),
              ],
            ),
            if (day.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(tr(context, 'plan.dayEmpty'),
                    style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant)),
              )
            else
              SizedBox(
                height: 76,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: day.cloths.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => _clothChip(context, day.cloths[i]),
                ),
              ),
            if (day.algo.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 8),
                child: Text(
                  trOr(context, 'algoName.${day.algo}', day.algo) +
                      (day.theme.isEmpty ? '' : ' · ${day.theme}'),
                  style: TextStyle(
                      fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            if (day.repeated)
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 8),
                child: Text(tr(context, 'plan.repeated'),
                    style: TextStyle(
                        fontSize: 11, color: theme.colorScheme.tertiary)),
              ),
            if (day.alreadyPlanned)
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 8),
                child: Text(tr(context, 'plan.alreadyPlanned'),
                    style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _clothChip(BuildContext context, PlanCloth cloth) {
    return SizedBox(
      width: 72,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: cloth.thumbUrl.isEmpty
                ? const ColoredBox(color: Colors.black12)
                : AppImage.path(cloth.thumbUrl, fit: BoxFit.contain),
          ),
          const SizedBox(height: 2),
          Text(cloth.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10)),
        ],
      ),
    );
  }
}
