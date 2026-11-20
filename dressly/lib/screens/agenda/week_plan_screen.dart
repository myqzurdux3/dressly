import 'package:flutter/material.dart';

import '../../app.dart';
import '../../design/ds.dart';
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
        if (_locked.contains(d.day) && d.clothIds.isNotEmpty) d.day: d.clothIds,
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
      showDragHandle: true,
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
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.skipped.isEmpty
                ? tr(context, 'plan.saved', {'count': '${result.created}'})
                : tr(context, 'plan.savedWithSkips', {
                    'count': '${result.created}',
                    'skipped': '${result.skipped.length}',
                  }),
          ),
        ),
      );
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
    final ds = context.ds;
    final plan = _plan;
    final busy = _loading || _saving;
    final canSave = plan != null && !plan.isEmpty && !busy;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                ds.space.gutter,
                ds.space.s,
                ds.space.gutter,
                0,
              ),
              child: Row(
                children: [
                  DsButton.icon(
                    icon: Icons.arrow_back,
                    semanticLabel: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    onPressed: () => Navigator.maybePop(context),
                  ),
                  const Spacer(),
                  DsButton.icon(
                    icon: Icons.tune,
                    semanticLabel: tr(context, 'week.title'),
                    onPressed: busy ? null : _openOptions,
                  ),
                  SizedBox(width: ds.space.xs),
                  DsButton.icon(
                    icon: Icons.refresh,
                    semanticLabel: tr(context, 'plan.redraw'),
                    onPressed: busy ? null : _draw,
                  ),
                ],
              ),
            ),
            if (_loading && _plan != null)
              LinearProgressIndicator(minHeight: 2, color: ds.colors.accent)
            else
              const SizedBox(height: 2),
            Expanded(child: _body()),
            Padding(
              padding: EdgeInsets.fromLTRB(
                ds.space.gutter,
                ds.space.s,
                ds.space.gutter,
                ds.space.m,
              ),
              child: DsButton(
                label: tr(context, 'plan.save'),
                icon: Icons.event_available,
                expand: true,
                loading: _saving,
                onPressed: canSave ? _save : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The rules the current week was drawn from, in one tappable line. Without
  /// it the options live behind an icon and the screen cannot say why it
  /// proposed what it proposed.
  Widget _optionsBar() {
    final ds = context.ds;
    final c = ds.colors;
    final names = [
      for (final a in _options.algos)
        trOr(context, 'algoName.${a.algo}', a.algo) +
            (a.value.isEmpty ? '' : ' · ${a.value}'),
    ].join(' + ');
    final weather = switch (_options.weather) {
      'hot' => tr(context, 'algo.hot'),
      'cold' => tr(context, 'algo.cold'),
      'auto' => tr(context, 'algo.autoWeather'),
      _ => tr(context, 'algo.any'),
    };
    final details = [
      weather,
      if (_options.categories.isNotEmpty)
        tr(context, 'week.typesCount', {
          'count': '${_options.categories.length}',
        }),
      if (_options.minScore > 0) '${_options.minScore}★+',
      if (_options.allowRepeatTheme) tr(context, 'week.repeatTheme'),
    ].join(' · ');
    return DsPressable(
      onTap: _loading || _saving ? null : _openOptions,
      child: Container(
        padding: EdgeInsets.all(ds.space.m),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: ds.shape.cardRadius,
        ),
        child: Row(
          children: [
            Icon(Icons.tune, color: c.accentText),
            SizedBox(width: ds.space.s),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    names.isEmpty ? tr(context, 'week.pickAtLeastOne') : names,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ds.typo.label,
                  ),
                  SizedBox(height: ds.space.xs / 2),
                  Text(
                    details.toUpperCase(),
                    style: ds.typo.mono.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: c.textMuted),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    final ds = context.ds;
    if (_loading && _plan == null) {
      return Center(child: CircularProgressIndicator(color: ds.colors.accent));
    }
    if (_error != null) {
      return DsError(
        message: '${tr(context, 'plan.loadError')}: $_error',
        retryLabel: tr(context, 'common.retry'),
        onRetry: _draw,
      );
    }
    final plan = _plan!;
    return ListView(
      children: [
        DsHeader(
          line1: tr(context, 'plan.title1'),
          line2: tr(context, 'plan.title2'),
          meta: [
            if (!plan.isEmpty)
              '${plan.days.where((d) => !d.isEmpty).length}/${plan.days.length}',
          ],
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: ds.space.gutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (plan.isEmpty)
                DsEmpty(
                  title: tr(context, 'plan.nothingToPlan'),
                  message: '',
                  actionLabel: tr(context, 'week.title'),
                  onAction: _openOptions,
                )
              else ...[
                _optionsBar(),
                Padding(
                  padding: EdgeInsets.symmetric(vertical: ds.space.s),
                  child: Text(
                    tr(context, 'plan.hint'),
                    style: ds.typo.label.copyWith(color: ds.colors.textMuted),
                  ),
                ),
                for (final day in plan.days)
                  Padding(
                    padding: EdgeInsets.only(bottom: ds.space.s),
                    child: _DayCard(
                      day: day,
                      locked: _locked.contains(day.day),
                      onToggleLock: () => _toggleLock(day),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
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
    final diff = DateTime(
      parsed.year,
      parsed.month,
      parsed.day,
    ).difference(today).inDays;
    if (diff == 0) return '${tr(context, 'plan.today')} · $label';
    if (diff == 1) return '${tr(context, 'plan.tomorrow')} · $label';
    return label;
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final note = ds.typo.mono.copyWith(color: c.textMuted);
    return AnimatedContainer(
      duration: ds.motion.fast,
      padding: EdgeInsets.fromLTRB(
        ds.space.m,
        ds.space.s,
        ds.space.xs,
        ds.space.m,
      ),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: ds.shape.cardRadius,
        border: Border.all(
          color: locked ? c.accent : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _dayLabel(context).toUpperCase(),
                  style: ds.typo.headline,
                ),
              ),
              if (day.weatherAvailable) ...[
                Icon(
                  day.weatherMode == 'hot'
                      ? Icons.wb_sunny_outlined
                      : Icons.ac_unit,
                  size: 16,
                  color: c.accentText,
                ),
                SizedBox(width: ds.space.xs / 2),
                Text(day.shortTemp, style: ds.typo.mono),
              ],
              IconButton(
                icon: Icon(locked ? Icons.lock : Icons.lock_open_outlined),
                color: locked ? c.accent : c.textMuted,
                tooltip: locked
                    ? tr(context, 'plan.unlockDay')
                    : tr(context, 'plan.lockDay'),
                onPressed: onToggleLock,
              ),
            ],
          ),
          if (day.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: ds.space.s),
              child: Text(
                tr(context, 'plan.dayEmpty'),
                style: ds.typo.label.copyWith(color: c.textMuted),
              ),
            )
          else
            SizedBox(
              height: 92,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: day.cloths.length,
                separatorBuilder: (_, _) => SizedBox(width: ds.space.xs),
                itemBuilder: (_, i) => _clothTile(context, day.cloths[i]),
              ),
            ),
          if (day.algo.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: ds.space.xs),
              child: Text(
                (trOr(context, 'algoName.${day.algo}', day.algo) +
                        (day.theme.isEmpty ? '' : ' · ${day.theme}'))
                    .toUpperCase(),
                style: note,
              ),
            ),
          if (day.repeated)
            Padding(
              padding: EdgeInsets.only(top: ds.space.xs / 2),
              child: DsBadge(
                text: tr(context, 'plan.repeated'),
                tone: DsBadgeTone.accent,
              ),
            ),
          if (day.alreadyPlanned)
            Padding(
              padding: EdgeInsets.only(top: ds.space.xs / 2),
              child: Text(tr(context, 'plan.alreadyPlanned'), style: note),
            ),
        ],
      ),
    );
  }

  Widget _clothTile(BuildContext context, PlanCloth cloth) {
    final ds = context.ds;
    final c = ds.colors;
    return SizedBox(
      width: 72,
      child: Column(
        children: [
          Expanded(
            child: Container(
              width: 72,
              padding: EdgeInsets.all(ds.space.xs / 2),
              decoration: BoxDecoration(
                color: c.surfaceHigh,
                borderRadius: ds.shape.smallRadius,
              ),
              child: cloth.thumbUrl.isEmpty
                  ? Icon(Icons.checkroom, color: c.textMuted)
                  : AppImage.path(cloth.thumbUrl, fit: BoxFit.contain),
            ),
          ),
          SizedBox(height: ds.space.xs / 2),
          Text(
            cloth.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ds.typo.mono.copyWith(color: c.textMuted, fontSize: 10),
          ),
        ],
      ),
    );
  }
}
