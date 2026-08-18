import 'package:flutter/material.dart';

import '../../app.dart';
import '../../l10n/app_text.dart';
import '../../models/agenda.dart';
import '../../models/outfit.dart';
import '../../widgets/app_image.dart';
import '../outfit/outfit_result_dialog.dart';
import 'week_plan_screen.dart';
import '../../theme/tones.dart';

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

  @override
  void initState() {
    super.initState();
    _reload();
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

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  void _toastKey(String key, [Object? err]) {
    if (!mounted) return;
    final msg = tr(context, key);
    _toast(err == null ? msg : '$msg: $err');
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
        context, MaterialPageRoute(builder: (_) => const WeekPlanScreen()));
    if (saved == true && mounted) _reload();
  }

  Future<void> _schedule() async {
    // Resolve services up front so they aren't read from `context` after the
    // date/sheet await gaps.
    final outfitsSvc = outfitsServiceOf(context);
    final agendaSvc = agendaServiceOf(context);
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
    );
    if (date == null || !mounted) return;

    // Fetch outfits to choose from (history). May be empty.
    List<Outfit> outfits = [];
    try {
      outfits = await outfitsSvc.list();
      outfits = outfits.where((o) => o.status != 'failed').toList();
    } catch (_) {}
    if (!mounted) return;

    final result = await showModalBottomSheet<_ScheduleResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (_) => _ScheduleSheet(outfits: outfits),
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
      _toastKey('agenda.added');
      _reload();
    } catch (e) {
      _toastKey('agenda.failed', e);
    }
  }

  Future<void> _markWorn(AgendaEntry e) async {
    try {
      await agendaServiceOf(context).markWorn(e.id, worn: !e.worn);
      _reload();
    } catch (err) {
      _toastKey('agenda.failed', err);
    }
  }

  Future<void> _delete(AgendaEntry e) async {
    try {
      await agendaServiceOf(context).delete(e.id);
      _reload();
    } catch (err) {
      _toastKey('agenda.deleteFailed', err);
    }
  }

  Future<void> _openOutfit(Outfit o) async {
    await showDialog<bool>(
      context: context,
      builder: (_) => OutfitResultDialog(outfit: o, onChanged: (_) {}),
    );
    if (mounted) _reload();
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
        child: Text(t.toUpperCase(),
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
                color: secondaryText(context))),
      );

  /// Renders entries grouped by day, with a day header before each new day.
  List<Widget> _dayGroups(List<AgendaEntry> list) {
    final out = <Widget>[];
    String? lastDay;
    for (final e in list) {
      if (e.day != lastDay) {
        out.add(Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
          child: Text(_fmtDay(context, e.day),
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        ));
        lastDay = e.day;
      }
      out.add(_AgendaCard(
        entry: e,
        onOpen: e.outfit == null ? null : () => _openOutfit(e.outfit!),
        onToggleWorn: () => _markWorn(e),
        onDelete: () => _delete(e),
      ));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'nav.agenda')),
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_awesome_motion_outlined),
            tooltip: tr(context, 'plan.title'),
            onPressed: _openWeekPlanner,
          ),
        ],
      ),
      floatingActionButton: _empty
          ? null
          : FloatingActionButton.extended(
              onPressed: _schedule,
              icon: const Icon(Icons.event),
              label: Text(tr(context, 'agenda.scheduleOutfit')),
            ),
      body: FutureBuilder<List<AgendaEntry>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('${tr(context, 'detail.error')}: ${snap.error}'));
          }
          final items = snap.data ?? [];
          if (items.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.event_note, size: 64, color: Colors.grey),
                  const SizedBox(height: 12),
                  Text(tr(context, 'agenda.empty')),
                  const SizedBox(height: 4),
                  Text(tr(context, 'agenda.emptyHint'),
                      style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 16),
                  // The hint above names "schedule an outfit", so that is what
                  // the button under it must do. It used to open the week
                  // planner instead — a different action, under a label the
                  // sentence had just told the reader to look for.
                  FilledButton.icon(
                    onPressed: _schedule,
                    icon: const Icon(Icons.event),
                    label: Text(tr(context, 'agenda.scheduleOutfit')),
                  ),
                  TextButton.icon(
                    onPressed: _openWeekPlanner,
                    icon: const Icon(Icons.auto_awesome_motion_outlined),
                    label: Text(tr(context, 'plan.title')),
                  ),
                ],
              ),
            );
          }
          // Split into upcoming (today onward, chronological) and past (most
          // recent first) so today's plan is on top and history is below.
          final now = DateTime.now();
          final today =
              '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
          final upcoming =
              items.where((e) => e.day.compareTo(today) >= 0).toList();
          final past = items.where((e) => e.day.compareTo(today) < 0).toList()
            ..sort((a, b) => b.day.compareTo(a.day));

          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _openWeekPlanner,
                    icon: const Icon(Icons.auto_awesome_motion_outlined, size: 18),
                    label: Text(tr(context, 'plan.title')),
                  ),
                ),
                const SizedBox(height: 8),
                if (upcoming.isNotEmpty) ...[
                  _sectionTitle(tr(context, 'agenda.upcoming')),
                  ..._dayGroups(upcoming),
                ],
                if (past.isNotEmpty) ...[
                  _sectionTitle(tr(context, 'agenda.previouslyWorn')),
                  ..._dayGroups(past),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

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
    final o = entry.outfit;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(children: [
          GestureDetector(
            onTap: onOpen,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 64,
                height: 64,
                color: Colors.blueGrey.shade900,
                // A planned day holds clothes and no image until you render it:
                // the tile showed a broken-image glyph, which reads as an error
                // rather than as "not generated yet".
                child: o == null || !o.hasRender
                    ? const Icon(Icons.checkroom, color: Colors.white38)
                    // A 64 px tile: the grid-sized copy, not the full render.
                    : AppImage(url: outfitThumbUrl(o),
                        cacheKey: outfitThumbUrl(o),
                        fit: BoxFit.cover, memWidth: 128),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.title.isNotEmpty
                      ? entry.title
                      : (o == null
                          ? tr(context, 'agenda.plannedDay')
                          : [
                              if (o.modelName != null) o.modelName!,
                              if (o.cloths.isNotEmpty)
                                o.cloths.map((c) => c.name).join(', '),
                            ].join(' · ')),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (entry.worn)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(tr(context, 'agenda.wornDone'),
                        style: TextStyle(
                            color: Colors.tealAccent, fontSize: 12)),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: entry.worn ? tr(context, 'agenda.markNotWorn') : tr(context, 'agenda.markWorn'),
            icon: Icon(entry.worn ? Icons.check_circle : Icons.check_circle_outline,
                color: entry.worn ? Colors.tealAccent : null),
            onPressed: onToggleWorn,
          ),
          IconButton(
            tooltip: tr(context, 'agenda.remove'),
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            onPressed: onDelete,
          ),
        ]),
      ),
    );
  }
}

class _ScheduleResult {
  final int? outfitId;
  final String title;
  _ScheduleResult({this.outfitId, this.title = ''});
}

/// Bottom sheet: optional title + pick which generated outfit to plan.
class _ScheduleSheet extends StatefulWidget {
  const _ScheduleSheet({required this.outfits});
  final List<Outfit> outfits;

  @override
  State<_ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends State<_ScheduleSheet> {
  final _title = TextEditingController();
  final _search = TextEditingController();
  int? _selected;
  bool _favOnly = false;
  String _query = '';

  @override
  void dispose() {
    _title.dispose();
    _search.dispose();
    super.dispose();
  }

  List<Outfit> get _filtered {
    final q = _query.trim().toLowerCase();
    return widget.outfits.where((o) {
      if (_favOnly && !o.isFavorite) return false;
      if (q.isEmpty) return true;
      final hay = [
        o.modelName ?? '',
        o.cloths.map((c) => c.name).join(' '),
        o.cloths.map((c) => c.brand).join(' '),
      ].join(' ').toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final outfits = _filtered;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        expand: false,
        builder: (context, scroll) => SingleChildScrollView(
          controller: scroll,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr(context, 'agenda.planDay'),
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              TextField(
                controller: _title,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: tr(context, 'agenda.label'),
                  hintText: tr(context, 'agenda.labelHint'),
                ),
              ),
              const SizedBox(height: 16),
              Text(tr(context, 'agenda.pickOutfit'),
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              if (widget.outfits.isEmpty)
                Text(tr(context, 'agenda.noOutfits'),
                    style: TextStyle(color: Colors.grey))
              else ...[
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _search,
                      onChanged: (v) => setState(() => _query = v),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: tr(context, 'agenda.searchHint'),
                        prefixIcon: const Icon(Icons.search, size: 20),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: Text(tr(context, 'agenda.saved')),
                    selected: _favOnly,
                    onSelected: (v) => setState(() => _favOnly = v),
                  ),
                ]),
                const SizedBox(height: 10),
                if (outfits.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(tr(context, 'agenda.noMatch'),
                        style: TextStyle(color: Colors.grey)),
                  )
                else
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 0.8,
                  ),
                  itemCount: outfits.length,
                  itemBuilder: (context, i) {
                    final o = outfits[i];
                    final sel = _selected == o.id;
                    return GestureDetector(
                      onTap: () =>
                          setState(() => _selected = sel ? null : o.id),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: sel ? Colors.tealAccent : Colors.white24,
                              width: sel ? 3 : 1),
                        ),
                        clipBehavior: Clip.antiAlias,
                        // Three per row: the grid-sized copy is plenty.
                        child: AppImage(url: outfitThumbUrl(o),
                            cacheKey: outfitThumbUrl(o),
                            fit: BoxFit.cover, memWidth: 160),
                      ),
                    );
                  },
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton(
                  onPressed: () => Navigator.pop(
                    context,
                    _ScheduleResult(
                        outfitId: _selected, title: _title.text.trim()),
                  ),
                  child: Text(tr(context, 'agenda.addToAgenda')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
