import 'package:flutter/material.dart';

import '../../app.dart';
import '../../design/ds.dart';
import '../../l10n/app_text.dart';
import '../wardrobe/wardrobe_card.dart' show swatchColorOf;
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
        items: [
          for (final it in report.items)
            if (it.cloth.id != clothId) it,
        ],
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
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            tr(context, 'dormant.markedWorn', {'name': item.cloth.name}),
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _toggleExclude(DormantCloth item) async {
    final svc = clothesServiceOf(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final excluded = await svc.setExcludeFromAlgo(
        item.cloth.id,
        exclude: !item.cloth.excludeFromAlgo,
      );
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
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            excluded
                ? tr(context, 'dormant.excluded')
                : tr(context, 'dormant.included'),
          ),
        ),
      );
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
            child: Text(tr(ctx, 'common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr(ctx, 'dormant.delete')),
          ),
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
        SnackBar(content: Text(tr(context, 'dormant.deleted'))),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return DsSubPage(
      title: tr(context, 'dormant.title'),
      onRefresh: _load,
      children: _body(),
    );
  }

  List<Widget> _body() {
    final ds = context.ds;
    if (_loading && _report == null) {
      return [
        Padding(
          padding: EdgeInsets.all(ds.space.xl),
          child: Center(
            child: CircularProgressIndicator(color: ds.colors.accent),
          ),
        ),
      ];
    }
    if (_error != null) {
      return [
        DsError(
          message: '${tr(context, 'dormant.loadError')}: $_error',
          retryLabel: tr(context, 'common.retry'),
          onRetry: _load,
        ),
      ];
    }
    final report = _report!;
    return [
      _header(report),
      SizedBox(height: ds.space.m),
      _thresholdPicker(),
      if (report.isEmpty)
        _emptyState(report)
      else ...[
        // Two groups, because they are two different problems: something
        // never once put on is a buying mistake, something dropped months ago
        // is a habit. Lumping them together made both harder to act on.
        ..._section(tr(context, 'dormant.neverWornTitle'), report.neverWorn),
        ..._section(
          trPlural(context, 'dormant.staleTitle', report.months),
          report.stale,
        ),
      ],
    ];
  }

  /// A titled group of cards, or nothing at all when the group is empty — an
  /// empty heading reads as a loading failure.
  List<Widget> _section(String title, List<DormantCloth> items) {
    if (items.isEmpty) return const [];
    final ds = context.ds;
    return [
      DsSectionTitle(title),
      for (final item in items)
        Padding(
          padding: EdgeInsets.only(bottom: ds.space.s),
          child: _DormantCard(
            item: item,
            onOpen: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ClothDetailScreen(clothId: item.cloth.id),
                ),
              );
              if (mounted) await _load();
            },
            onWear: () => _wearToday(item),
            onToggleExclude: () => _toggleExclude(item),
            onDelete: () => _confirmDelete(item),
          ),
        ),
    ];
  }

  Widget _header(DormantReport report) {
    final ds = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr(context, 'dormant.headline', {
            'count': '${report.count}',
            'total': '${report.wardrobeCount}',
          }),
          style: ds.typo.title,
        ),
        SizedBox(height: ds.space.xs / 2),
        Text(
          tr(context, 'dormant.subhead', {
            'percent': '${report.percentOfWardrobe}',
            'never': '${report.neverWornCount}',
            'stale': '${report.staleCount}',
          }).toUpperCase(),
          style: ds.typo.mono.copyWith(color: ds.colors.textMuted),
        ),
      ],
    );
  }

  Widget _thresholdPicker() {
    return DsSegment<int>(
      options: [
        for (final m in _thresholds)
          (m, trPlural(context, 'dormant.months', m)),
      ],
      value: _months,
      onChanged: (m) {
        if (!_loading) _setMonths(m);
      },
    );
  }

  Widget _emptyState(DormantReport report) {
    return DsEmpty(
      title: report.wardrobeCount == 0
          ? tr(context, 'dormant.emptyWardrobe')
          : tr(context, 'dormant.nothingDormant'),
      message: '',
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
    final ds = context.ds;
    final c = ds.colors;
    final Cloth cloth = item.cloth;
    final url = cloth.thumbImageUrl;
    final tone = garmentTone(
      swatchColorOf(cloth),
      Theme.of(context).brightness,
    );
    return DsPressable(
      onTap: onOpen,
      child: Container(
        padding: EdgeInsets.all(ds.space.s),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: ds.shape.cardRadius,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 80,
                  height: 96,
                  padding: EdgeInsets.all(ds.space.xs),
                  decoration: BoxDecoration(
                    color: tone.fill,
                    borderRadius: ds.shape.smallRadius,
                  ),
                  child: url == null
                      ? Icon(Icons.checkroom, color: tone.onFill)
                      : AppImage.path(
                          url,
                          cacheKey: url,
                          fit: BoxFit.contain,
                          memWidth: 200,
                        ),
                ),
                SizedBox(width: ds.space.s),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Body type, not the display face: a garment name is a
                      // sentence-case phrase that must stay readable in full.
                      Text(
                        cloth.name,
                        style: ds.typo.bodyStrong,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        (item.neverWorn
                                ? tr(context, 'dormant.neverWorn', {
                                    'age': _age(context),
                                  })
                                : tr(context, 'dormant.notWornSince', {
                                    'age': _age(context),
                                    'times': '${item.timesWorn}',
                                  }))
                            .toUpperCase(),
                        style: ds.typo.monoSmall.copyWith(color: c.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: ds.space.s),
            // One row: two labelled actions that shrink if they must,
            // and the destructive one as an icon at the end.
            Row(
              children: [
                Flexible(
                  child: _Action(
                    icon: Icons.check,
                    label: tr(context, 'dormant.wearToday'),
                    onTap: onWear,
                  ),
                ),
                SizedBox(width: ds.space.xs),
                Flexible(
                  child: _Action(
                    icon: cloth.excludeFromAlgo
                        ? Icons.visibility_outlined
                        : Icons.block_outlined,
                    label: cloth.excludeFromAlgo
                        ? tr(context, 'dormant.includeAgain')
                        : tr(context, 'dormant.exclude'),
                    onTap: onToggleExclude,
                  ),
                ),
                SizedBox(width: ds.space.xs),
                _Action(
                  icon: Icons.delete_outline,
                  label: tr(context, 'dormant.delete'),
                  onTap: onDelete,
                  danger: true,
                  iconOnly: true,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Small pill action under a card.
class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
    this.iconOnly = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  /// Show only the icon; [label] becomes the tooltip and the semantic label.
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final ink = danger ? c.danger : c.text;
    final pill = Material(
      color: c.surfaceHigh,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: ds.space.s,
            vertical: ds.space.xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: ink),
              if (!iconOnly) ...[
                SizedBox(width: ds.space.xs / 2),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ds.typo.label.copyWith(color: ink),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (!iconOnly) return pill;
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        button: true,
        excludeSemantics: true,
        child: pill,
      ),
    );
  }
}
