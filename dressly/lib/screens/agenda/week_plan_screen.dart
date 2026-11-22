import 'package:flutter/material.dart';

import '../../app.dart';
import '../../design/ds.dart';
import '../../l10n/app_text.dart';
import '../../models/cloth.dart';
import '../../models/outfit.dart';
import '../../models/plan.dart';
import '../../widgets/app_image.dart';
import '../../widgets/outfit_pick_grid.dart';
import 'week_options_sheet.dart';
import '../../widgets/error_toast.dart';

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

  /// Days pinned to one of the user's existing outfits (day -> outfit id).
  final Map<String, int> _pinnedOutfits = {};

  /// The user's outfits, for "choose an outfit" on a day. Loaded on first use.
  List<Outfit>? _outfits;

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
        if (_locked.contains(d.day) &&
            d.clothIds.isNotEmpty &&
            d.outfitId == null &&
            !_pinnedOutfits.containsKey(d.day))
          d.day: d.clothIds,
    };
  }

  /// Locked days that wear an existing outfit, plus days just pinned to one.
  Map<String, int> get _keepOutfits {
    final plan = _plan;
    return {
      if (plan != null)
        for (final d in plan.days)
          if (_locked.contains(d.day) && d.outfitId != null) d.day: d.outfitId!,
      ..._pinnedOutfits,
    };
  }

  /// Put one of the user's outfits on [day], then redraw around it.
  Future<void> _pickOutfit(PlanDay day) async {
    final title = tr(context, 'plan.pickOutfit');
    var outfits = _outfits;
    if (outfits == null) {
      try {
        outfits = (await outfitsServiceOf(context).list())
            .where((o) => o.status == 'done' && o.generatedUrl.isNotEmpty)
            .toList();
        _outfits = outfits;
      } catch (e) {
        toastError(e);
        return;
      }
    }
    if (!mounted) return;
    final id = await showOutfitPicker(
      context,
      outfits: outfits,
      title: title,
      initial: _pinnedOutfits[day.day] ?? day.outfitId,
    );
    if (id == null || !mounted) return;
    setState(() {
      _pinnedOutfits[day.day] = id;
      _locked.add(day.day);
    });
    await _draw();
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
      final plan = await svc.preview(
        keep: keep,
        keepOutfits: _keepOutfits,
        options: _options,
      );
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
      final result = await svc.apply(plan.applicable, outfits: plan.outfits);
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
      toastError(e);
    }
  }

  void _toggleLock(PlanDay day) {
    setState(() {
      if (_locked.remove(day.day)) {
        _pinnedOutfits.remove(day.day);
      } else {
        _locked.add(day.day);
      }
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
    final source = switch (_options.source) {
      'outfits' => tr(context, 'week.sourceOutfits'),
      'mix' => tr(context, 'week.sourceMix'),
      _ => '',
    };
    final details = [
      if (source.isNotEmpty) source,
      if (_options.holdDays > 1)
        tr(context, 'week.holdShort', {'count': '${_options.holdDays}'}),
      if (_options.holdByCategory.isNotEmpty)
        tr(context, 'week.holdByTypeCount', {
          'count': '${_options.holdByCategory.length}',
        }),
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
                    _options.source == 'outfits'
                        ? tr(context, 'week.sourceOutfits')
                        : (names.isEmpty
                              ? tr(context, 'week.pickAtLeastOne')
                              : names),
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
                      onPickOutfit: _loading || _saving
                          ? null
                          : () => _pickOutfit(day),
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
    this.onPickOutfit,
  });

  final PlanDay day;
  final bool locked;
  final VoidCallback onToggleLock;
  final VoidCallback? onPickOutfit;

  String _dayLabel(BuildContext context) {
    final parsed = DateTime.tryParse(day.day);
    if (parsed == null) return day.day;
    // The platform's own formatter: localised weekday and month names for free,
    // instead of an English list hard-coded in the app.
    final loc = MaterialLocalizations.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = DateTime(
      parsed.year,
      parsed.month,
      parsed.day,
    ).difference(today).inDays;
    // Today and tomorrow already name the day: the short date ("Nov 22")
    // keeps the line on one row.
    if (diff == 0) {
      return '${tr(context, 'plan.today')} · ${loc.formatShortMonthDay(parsed)}';
    }
    if (diff == 1) {
      return '${tr(context, 'plan.tomorrow')} · '
          '${loc.formatShortMonthDay(parsed)}';
    }
    return loc.formatMediumDate(parsed);
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
                icon: const Icon(Icons.swap_horiz),
                color: c.textMuted,
                tooltip: tr(context, 'plan.pickOutfit'),
                onPressed: onPickOutfit,
              ),
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
              child: Row(
                children: [
                  // An existing outfit shows its picture first.
                  if (day.outfitThumbUrl.isNotEmpty) ...[
                    ClipRRect(
                      borderRadius: ds.shape.smallRadius,
                      child: SizedBox(
                        width: 72,
                        height: 92,
                        child: AppImage.path(
                          day.outfitThumbUrl,
                          cacheKey: day.outfitThumbUrl,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    SizedBox(width: ds.space.xs),
                  ],
                  Expanded(
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      // The card's right padding is tight for the icon
                      // buttons; the last thumbnail still gets a margin.
                      padding: EdgeInsets.only(right: ds.space.s),
                      itemCount: day.cloths.length,
                      separatorBuilder: (_, _) => SizedBox(width: ds.space.xs),
                      itemBuilder: (_, i) => _clothTile(
                        context,
                        day.cloths[i],
                        carried: day.carriedIds.contains(day.cloths[i].id),
                      ),
                    ),
                  ),
                ],
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
          if (day.isContinued || day.source == 'outfit')
            Padding(
              padding: EdgeInsets.only(top: ds.space.xs / 2),
              child: Wrap(
                spacing: ds.space.xs,
                children: [
                  if (day.source == 'outfit')
                    DsBadge(text: tr(context, 'plan.myOutfit')),
                  if (day.isContinued)
                    DsBadge(text: tr(context, 'plan.continued')),
                ],
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

  Widget _clothTile(
    BuildContext context,
    PlanCloth cloth, {
    bool carried = false,
  }) {
    final ds = context.ds;
    final c = ds.colors;
    // The picture says what it is; the name stays for screen readers (a
    // 10 px caption truncated after a few letters helped nobody).
    return Semantics(
      label: cloth.name,
      image: true,
      child: SizedBox(
        width: 72,
        child: Container(
          padding: EdgeInsets.all(ds.space.xs / 2),
          decoration: BoxDecoration(
            color: c.surfaceHigh,
            borderRadius: ds.shape.smallRadius,
            // Worn again from the day before: outlined, so a held jogging
            // reads at a glance.
            border: carried
                ? Border.all(color: c.accent.withValues(alpha: 0.6))
                : null,
          ),
          child: cloth.thumbUrl.isEmpty
              ? Icon(Icons.checkroom, color: c.textMuted)
              : AppImage.path(cloth.thumbUrl, fit: BoxFit.contain),
        ),
      ),
    );
  }
}
