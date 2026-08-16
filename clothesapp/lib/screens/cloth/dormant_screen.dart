import 'package:flutter/material.dart';

import '../../app.dart';
import '../../l10n/app_text.dart';
import '../../models/cloth.dart';
import '../../models/dormant.dart';
import '../../widgets/app_image.dart';
import 'cloth_detail_screen.dart';

/// What you own and never reach for.
///
/// The wardrobe already records when each piece was last worn; this reads it
/// back and puts the three useful answers next to each garment: wear it, stop
/// letting the algorithms pick it, or let it go.
class DormantScreen extends StatefulWidget {
  const DormantScreen({super.key});

  @override
  State<DormantScreen> createState() => _DormantScreenState();
}

class _DormantScreenState extends State<DormantScreen> {
  /// Thresholds worth offering: a season, half a year, a full year. Anything
  /// finer is noise — a garment is not "forgotten" by a fortnight.
  static const _thresholds = [3, 6, 12];

  int _months = 6;
  DormantReport? _report;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final svc = clothesServiceOf(context); // before the await gap
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final report = await svc.dormant(months: _months);
      if (!mounted) return;
      setState(() {
        _report = report;
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

  Future<void> _setMonths(int months) async {
    if (months == _months) return;
    setState(() => _months = months);
    await _load();
  }

  /// Drop one card without refetching the list: the item has just left the set
  /// by definition (worn, or deleted), and a full reload would make the row the
  /// user just tapped jump somewhere else under their finger.
  void _removeLocally(int clothId) {
    final report = _report;
    if (report == null) return;
    setState(() {
      _report = DormantReport(
        months: report.months,
        count: (report.count - 1).clamp(0, report.count),
        wardrobeCount: report.wardrobeCount,
        items: [for (final it in report.items) if (it.cloth.id != clothId) it],
      );
    });
  }

  Future<void> _wearToday(DormantCloth item) async {
    final svc = clothesServiceOf(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await svc.wear(item.cloth.id);
      if (!mounted) return;
      _removeLocally(item.cloth.id);
      messenger.showSnackBar(SnackBar(
          content: Text(tr(context, 'dormant.markedWorn',
              {'name': item.cloth.name}))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _toggleExclude(DormantCloth item) async {
    final svc = clothesServiceOf(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final excluded = await svc.setExcludeFromAlgo(item.cloth.id,
          exclude: !item.cloth.excludeFromAlgo);
      if (!mounted) return;
      final report = _report;
      if (report != null) {
        setState(() {
          _report = DormantReport(
            months: report.months,
            count: report.count,
            wardrobeCount: report.wardrobeCount,
            items: [
              for (final it in report.items)
                if (it.cloth.id == item.cloth.id)
                  DormantCloth(
                    // Patched in place rather than refetched: the row must not
                    // move under the finger that just tapped it.
                    cloth: it.cloth.copyWith(excludeFromAlgo: excluded),
                    dormantDays: it.dormantDays,
                    dormantSince: it.dormantSince,
                    neverWorn: it.neverWorn,
                    timesWorn: it.timesWorn,
                  )
                else
                  it,
            ],
          );
        });
      }
      messenger.showSnackBar(SnackBar(
          content: Text(excluded
              ? tr(context, 'dormant.excluded')
              : tr(context, 'dormant.included'))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _confirmDelete(DormantCloth item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'dormant.deleteTitle')),
        content: Text(tr(ctx, 'dormant.deleteBody', {'name': item.cloth.name})),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr(ctx, 'common.cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr(ctx, 'dormant.delete'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final svc = clothesServiceOf(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await svc.delete(item.cloth.id);
      if (!mounted) return;
      _removeLocally(item.cloth.id);
      messenger.showSnackBar(
          SnackBar(content: Text(tr(context, 'dormant.deleted'))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'dormant.title'))),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _body(),
      ),
    );
  }

  Widget _body() {
    if (_loading && _report == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ListView(children: [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text('${tr(context, 'dormant.loadError')}: $_error',
              textAlign: TextAlign.center),
        ),
      ]);
    }
    final report = _report!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _header(report),
        const SizedBox(height: 12),
        _thresholdPicker(),
        const SizedBox(height: 16),
        if (report.isEmpty)
          _emptyState(report)
        else ...[
          // Two groups, because they are two different problems: something
          // never once put on is a buying mistake, something dropped months ago
          // is a habit. Lumping them together made both harder to act on.
          ..._section(tr(context, 'dormant.neverWornTitle'), report.neverWorn),
          ..._section(
              trPlural(context, 'dormant.staleTitle', report.months),
              report.stale),
        ],
      ],
    );
  }

  /// A titled group of cards, or nothing at all when the group is empty — an
  /// empty heading reads as a loading failure.
  List<Widget> _section(String title, List<DormantCloth> items) {
    if (items.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      ),
      for (final item in items) ...[
        _DormantCard(
          item: item,
          onOpen: () async {
            await Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => ClothDetailScreen(clothId: item.cloth.id)));
            if (mounted) await _load();
          },
          onWear: () => _wearToday(item),
          onToggleExclude: () => _toggleExclude(item),
          onDelete: () => _confirmDelete(item),
        ),
        const SizedBox(height: 10),
      ],
    ];
  }

  Widget _header(DormantReport report) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr(context, 'dormant.headline', {
            'count': '${report.count}',
            'total': '${report.wardrobeCount}',
          }),
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          tr(context, 'dormant.subhead', {
            'percent': '${report.percentOfWardrobe}',
            'never': '${report.neverWornCount}',
            'stale': '${report.staleCount}',
          }),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _thresholdPicker() {
    return Wrap(
      spacing: 8,
      children: [
        for (final m in _thresholds)
          ChoiceChip(
            label: Text(trPlural(context, 'dormant.months', m)),
            selected: _months == m,
            onSelected: _loading ? null : (_) => _setMonths(m),
          ),
      ],
    );
  }

  Widget _emptyState(DormantReport report) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(Icons.check_circle_outline,
              size: 48, color: theme.colorScheme.primary),
          const SizedBox(height: 12),
          Text(
            report.wardrobeCount == 0
                ? tr(context, 'dormant.emptyWardrobe')
                : tr(context, 'dormant.nothingDormant'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

/// One garment: its photo, how long it has sat there, and the three ways out.
class _DormantCard extends StatelessWidget {
  const _DormantCard({
    required this.item,
    required this.onOpen,
    required this.onWear,
    required this.onToggleExclude,
    required this.onDelete,
  });

  final DormantCloth item;
  final VoidCallback onOpen;
  final VoidCallback onWear;
  final VoidCallback onToggleExclude;
  final VoidCallback onDelete;

  String _age(BuildContext context) {
    // Days are exact but unreadable past a few weeks ("worn 412 days ago").
    if (item.dormantMonths >= 1) {
      return trPlural(context, 'dormant.months', item.dormantMonths);
    }
    return trPlural(context, 'dormant.days', item.dormantDays);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Cloth cloth = item.cloth;
    final url = cloth.thumbImageUrl;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 72,
                  height: 72,
                  child: url == null
                      ? const ColoredBox(color: Colors.black12)
                      : AppImage(url: url, fit: BoxFit.contain),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(cloth.name,
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                      item.neverWorn
                          ? tr(context, 'dormant.neverWorn',
                              {'age': _age(context)})
                          : tr(context, 'dormant.notWornSince',
                              {'age': _age(context), 'times': '${item.timesWorn}'}),
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 4,
                      children: [
                        TextButton.icon(
                          onPressed: onWear,
                          icon: const Icon(Icons.check, size: 18),
                          label: Text(tr(context, 'dormant.wearToday')),
                        ),
                        TextButton.icon(
                          onPressed: onToggleExclude,
                          icon: Icon(
                              cloth.excludeFromAlgo
                                  ? Icons.visibility_outlined
                                  : Icons.block_outlined,
                              size: 18),
                          label: Text(cloth.excludeFromAlgo
                              ? tr(context, 'dormant.includeAgain')
                              : tr(context, 'dormant.exclude')),
                        ),
                        TextButton.icon(
                          onPressed: onDelete,
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: Text(tr(context, 'dormant.delete')),
                          style: TextButton.styleFrom(
                              foregroundColor: theme.colorScheme.error),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
