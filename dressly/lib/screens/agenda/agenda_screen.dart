import 'package:flutter/material.dart';

import '../../state/data_bus.dart';
import '../../widgets/outfit_pending_image.dart';

import '../../app.dart';
import '../../design/ds.dart';
import '../../l10n/app_text.dart';
import '../../models/agenda.dart';
import '../../models/outfit.dart';
import '../../widgets/app_image.dart';
import '../../widgets/outfit_pick_grid.dart';
import '../outfit/outfit_result_dialog.dart';
import 'week_plan_screen.dart';
import '../../widgets/error_toast.dart';

/// Plan which outfit to wear on which day. Each entry can reference a generated
/// outfit; marking it worn stamps last_worn_at on that outfit's clothes (which
/// feeds the "not worn recently" generator algorithm).
class AgendaScreen extends StatefulWidget {
  const AgendaScreen({super.key});

  @override
  State<AgendaScreen> createState() => _AgendaScreenState();
}

class _AgendaScreenState extends State<AgendaScreen> {
  Future<List<AgendaEntry>>? _future;

  /// Whether the last load came back empty. The empty state offers the very
  /// action the button does, so showing both puts "Planifier une tenue" on the
  /// screen twice.
  bool _empty = false;

  /// Day picked in the strip; null shows every upcoming day.
  DateTime? _day;

  @override
  void initState() {
    super.initState();
    _reload();
    DataBus.agenda.addListener(_reload);
  }

  @override
  void dispose() {
    DataBus.agenda.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    setState(() {
      _future = agendaServiceOf(context).list().then((entries) {
        if (mounted && _empty != entries.isEmpty) {
          setState(() => _empty = entries.isEmpty);
        }
        return entries;
      });
    });
  }

  /// Same treatment as the week planner (week_plan_screen._dayLabel): the
  /// platform's own formatter gives localised weekday and month names, instead
  /// of the English lists that used to be hard-coded here.
  static String _fmtDay(BuildContext context, String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    final today = DateTime.now();
    final t0 = DateTime(today.year, today.month, today.day);
    final d0 = DateTime(d.year, d.month, d.day);
    final diff = d0.difference(t0).inDays;
    final label = MaterialLocalizations.of(context).formatMediumDate(d);
    if (diff == 0) return '${tr(context, 'plan.today')} · $label';
    if (diff == 1) return '${tr(context, 'plan.tomorrow')} · $label';
    if (diff == -1) return '${tr(context, 'agenda.yesterday')} · $label';
    return label;
  }

  /// The week planner. Reached from the app bar, from the top of the list and
  /// from the empty state: an unlabelled icon in a corner was not found.
  Future<void> _openWeekPlanner() async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const WeekPlanScreen()),
    );
    if (saved == true && mounted) _reload();
  }

  /// [date] given (a day picked in the strip): no date picker.
  Future<void> _schedule({DateTime? date}) async {
    // Resolve services up front so they aren't read from `context` after the
    // date/sheet await gaps.
    final outfitsSvc = outfitsServiceOf(context);
    final agendaSvc = agendaServiceOf(context);
    final now = DateTime.now();
    date ??= await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
    );
    if (date == null || !mounted) return;

    // Outfits to choose from (history). Loaded by the sheet itself, so a
    // failure shows an error with a retry instead of passing for "no outfits".
    final result = await showModalBottomSheet<_ScheduleResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ScheduleSheet(
        load: () async => [
          for (final o in await outfitsSvc.list())
            if (o.status != 'failed') o,
        ],
      ),
    );
    if (result == null) return;

    final iso =
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    try {
      await agendaSvc.create(
        day: iso,
        outfitId: result.outfitId,
        title: result.title,
      );
      toastKey('agenda.added');
      _reload();
    } catch (e) {
      toastError(e, prefixKey: 'agenda.failed');
    }
  }

  Future<void> _markWorn(AgendaEntry e) async {
    try {
      await agendaServiceOf(context).markWorn(e.id, worn: !e.worn);
      _reload();
    } catch (err) {
      toastError(err, prefixKey: 'agenda.failed');
    }
  }

  Future<void> _delete(AgendaEntry e) async {
    try {
      await agendaServiceOf(context).delete(e.id);
      _reload();
    } catch (err) {
      toastError(err, prefixKey: 'agenda.deleteFailed');
    }
  }

  Future<void> _openOutfit(Outfit o) async {
    await showDialog<bool>(
      context: context,
      builder: (_) => OutfitResultDialog(outfit: o, onChanged: (_) {}),
    );
    if (mounted) _reload();
  }

  /// Next seven days for the strip, each marked when something is planned.
  List<DsDay> _week(BuildContext context, List<AgendaEntry> items) {
    final names = tr(context, 'weekday.short').split(',');
    final now = DateTime.now();
    final planned = {for (final e in items) e.day};
    return [
      for (var i = 0; i < 7; i++)
        () {
          final d = DateTime(now.year, now.month, now.day + i);
          return DsDay(
            date: d,
            weekday: names.length == 7 ? names[d.weekday - 1] : '',
            hasPlan: planned.contains(_iso(d)),
          );
        }(),
    ];
  }

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Renders entries grouped by day, with a day header before each new day.
  List<Widget> _dayGroups(List<AgendaEntry> list) {
    final ds = context.ds;
    final out = <Widget>[];
    String? lastDay;
    for (final e in list) {
      if (e.day != lastDay) {
        out.add(
          Padding(
            padding: EdgeInsets.only(top: ds.space.m, bottom: ds.space.xs),
            child: Text(
              _fmtDay(context, e.day).toUpperCase(),
              style: ds.typo.mono.copyWith(color: ds.colors.textMuted),
            ),
          ),
        );
        lastDay = e.day;
      }
      out.add(
        Padding(
          padding: EdgeInsets.only(bottom: ds.space.s),
          child: _AgendaCard(
            entry: e,
            onOpen: e.outfit == null ? null : () => _openOutfit(e.outfit!),
            onToggleWorn: () => _markWorn(e),
            onDelete: () => _delete(e),
          ),
        ),
      );
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final pad = EdgeInsets.symmetric(horizontal: ds.space.gutter);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: FutureBuilder<List<AgendaEntry>>(
          future: _future,
          builder: (context, snap) {
            final items = snap.data ?? const <AgendaEntry>[];
            final today = _iso(DateTime.now());
            final upcoming = items
                .where((e) => e.day.compareTo(today) >= 0)
                .toList();
            final past = items.where((e) => e.day.compareTo(today) < 0).toList()
              ..sort((a, b) => b.day.compareTo(a.day));
            final day = _day;
            final shown = day == null
                ? upcoming
                : upcoming.where((e) => e.day == _iso(day)).toList();

            final header = <Widget>[
              DsHeader(
                line1: tr(context, 'agenda.title1'),
                line2: tr(context, 'agenda.title2'),
                meta: [
                  if (upcoming.isNotEmpty)
                    '${upcoming.length} ${tr(context, 'agenda.upcoming')}',
                ],
              ),
            ];

            Widget body;
            if (snap.connectionState == ConnectionState.waiting &&
                !snap.hasData) {
              body = Padding(
                padding: EdgeInsets.all(ds.space.xl),
                child: Center(
                  child: CircularProgressIndicator(color: c.accent),
                ),
              );
            } else if (snap.hasError) {
              body = DsError(
                message: '${tr(context, 'detail.error')}: ${snap.error}',
                retryLabel: tr(context, 'common.retry'),
                onRetry: _reload,
              );
            } else if (items.isEmpty) {
              // The sentence names "schedule an outfit", so that is what the
              // main button does; the week planner sits under it.
              body = Padding(
                padding: pad,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DsEmpty(
                      title: tr(context, 'agenda.empty'),
                      message: tr(context, 'agenda.emptyHint'),
                      actionLabel: tr(context, 'agenda.scheduleOutfit'),
                      onAction: _schedule,
                    ),
                    SizedBox(height: ds.space.s),
                    Center(
                      child: DsButton(
                        label: tr(context, 'plan.title'),
                        icon: Icons.auto_awesome_motion_outlined,
                        kind: DsButtonKind.secondary,
                        onPressed: _openWeekPlanner,
                      ),
                    ),
                  ],
                ),
              );
            } else {
              body = Padding(
                padding: pad,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: DsButton(
                            label: tr(context, 'agenda.scheduleOutfit'),
                            icon: Icons.event,
                            expand: true,
                            onPressed: () => _schedule(date: day),
                          ),
                        ),
                        SizedBox(width: ds.space.xs),
                        DsButton(
                          label: tr(context, 'plan.short'),
                          icon: Icons.auto_awesome_motion_outlined,
                          kind: DsButtonKind.secondary,
                          onPressed: _openWeekPlanner,
                        ),
                      ],
                    ),
                    SizedBox(height: ds.space.m),
                    // Tap a day to see only it; tap it again for everything.
                    DsDayStrip(
                      days: _week(context, items),
                      selected: day ?? DateTime(0),
                      onSelect: (d) => setState(
                        () => _day = (day != null && _iso(day) == _iso(d))
                            ? null
                            : d,
                      ),
                    ),
                    if (day != null && shown.isEmpty) ...[
                      SizedBox(height: ds.space.m),
                      DsPlanCard(
                        title: _fmtDay(context, _iso(day)),
                        subtitle: tr(context, 'agenda.nothingThatDay'),
                        thumbs: const [],
                        onTap: () => _schedule(date: day),
                      ),
                    ],
                    if (shown.isNotEmpty) ...[
                      DsSectionTitle(tr(context, 'agenda.upcoming')),
                      ..._dayGroups(shown),
                    ],
                    if (day == null && past.isNotEmpty) ...[
                      DsSectionTitle(tr(context, 'agenda.previouslyWorn')),
                      ..._dayGroups(past),
                    ],
                  ],
                ),
              );
            }

            return RefreshIndicator(
              color: c.accent,
              onRefresh: () async => _reload(),
              child: ListView(
                padding: EdgeInsets.only(bottom: ds.space.xl),
                children: [...header, body],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// One planned day: the outfit's picture, what it is, and its two actions.
class _AgendaCard extends StatelessWidget {
  const _AgendaCard({
    required this.entry,
    required this.onOpen,
    required this.onToggleWorn,
    required this.onDelete,
  });

  final AgendaEntry entry;
  final VoidCallback? onOpen;
  final VoidCallback onToggleWorn;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final o = entry.outfit;
    final title = entry.title.isNotEmpty
        ? entry.title
        : (o == null
              ? tr(context, 'agenda.plannedDay')
              : [
                  ?o.modelName,
                  if (o.cloths.isNotEmpty)
                    o.cloths.map((c) => c.name).join(', '),
                ].join(' · '));
    final subtitle = [
      if (o != null && o.cloths.isNotEmpty && entry.title.isNotEmpty)
        o.cloths.map((c) => c.name).join(', '),
      if (entry.worn) tr(context, 'agenda.wornDone'),
    ].join(' · ');
    return DsPlanCard(
      title: title,
      subtitle: subtitle,
      // A planned day holds clothes and no image until it is rendered: no
      // tile then, rather than a broken-image glyph that reads as an error.
      thumbs: [
        if (o != null && o.isProcessing)
          OutfitPendingImage(outfit: o, compact: true)
        else if (o != null && o.hasRender)
          AppImage(
            url: outfitThumbUrl(o),
            cacheKey: outfitThumbUrl(o),
            fit: BoxFit.cover,
            memWidth: 128,
          )
        else
          const Icon(Icons.checkroom),
      ],
      onTap: onOpen,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: tr(
              context,
              entry.worn ? 'agenda.markNotWorn' : 'agenda.markWorn',
            ),
            icon: Icon(
              entry.worn ? Icons.check_circle : Icons.check_circle_outline,
              color: entry.worn ? ds.colors.accent : null,
            ),
            onPressed: onToggleWorn,
          ),
          IconButton(
            tooltip: tr(context, 'agenda.remove'),
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _ScheduleResult {
  final int? outfitId;
  final String title;
  _ScheduleResult({this.outfitId, this.title = ''});
}

/// Sheet: optional label, then which generated outfit to plan.
class _ScheduleSheet extends StatefulWidget {
  const _ScheduleSheet({required this.load});

  /// Fetches the outfits to pick from; called again on retry.
  final Future<List<Outfit>> Function() load;

  @override
  State<_ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends State<_ScheduleSheet> {
  final _title = TextEditingController();
  int? _selected;
  late Future<List<Outfit>> _outfits = widget.load();

  void _retry() {
    setState(() {
      _outfits = widget.load();
    });
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: DraggableScrollableSheet(
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        expand: false,
        // Header and label on top, the outfits scrolling in between, and the
        // confirm button always on screen: with hundreds of outfits it used to
        // sit after the last thumbnail.
        builder: (context, scroll) => Padding(
          padding: EdgeInsets.fromLTRB(
            ds.space.gutter,
            ds.space.m,
            ds.space.gutter,
            ds.space.m,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                tr(context, 'agenda.planDay').toUpperCase(),
                style: ds.typo.headline,
              ),
              DsSectionTitle(tr(context, 'agenda.label')),
              TextField(
                controller: _title,
                decoration: InputDecoration(
                  hintText: tr(context, 'agenda.labelHint'),
                ),
              ),
              DsSectionTitle(tr(context, 'agenda.pickOutfit')),
              Expanded(
                child: FutureBuilder<List<Outfit>>(
                  future: _outfits,
                  builder: (context, snap) {
                    // Waiting first: on retry the snapshot keeps the previous
                    // error until the new future completes.
                    if (snap.connectionState != ConnectionState.done) {
                      return Center(
                        child: CircularProgressIndicator(
                          color: ds.colors.accent,
                        ),
                      );
                    }
                    if (snap.hasError) {
                      return DsError(
                        message: tr(context, 'common.loadFailed'),
                        retryLabel: tr(context, 'common.retry'),
                        onRetry: _retry,
                      );
                    }
                    return OutfitPickGrid(
                      outfits: snap.data ?? const [],
                      selected: _selected,
                      controller: scroll,
                      onSelected: (id) => setState(() => _selected = id),
                    );
                  },
                ),
              ),
              SizedBox(height: ds.space.s),
              DsButton(
                label: tr(context, 'agenda.addToAgenda'),
                expand: true,
                onPressed: () => Navigator.pop(
                  context,
                  _ScheduleResult(
                    outfitId: _selected,
                    title: _title.text.trim(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
