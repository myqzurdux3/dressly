import 'package:flutter/material.dart';

import '../../app.dart';
import '../../design/ds.dart';
import '../../l10n/app_text.dart';
import '../../models/costs.dart';

/// What the paid services have cost, in dollars: OpenRouter renders, the BFL
/// cascade and the stylist, over a chosen period, then the latest calls.
class CostsScreen extends StatefulWidget {
  const CostsScreen({super.key});

  @override
  State<CostsScreen> createState() => _CostsScreenState();
}

class _CostsScreenState extends State<CostsScreen> {
  GenerationCosts? _costs;
  Object? _error;
  bool _loading = true;
  String _period = 'month';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final svc = adminServiceOf(context);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final got = await svc.costs();
      if (!mounted) return;
      setState(() {
        _costs = got;
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

  static String usd(double v) =>
      v < 1 ? '\$${v.toStringAsFixed(3)}' : '\$${v.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    return DsSubPage(
      title: tr(context, 'costs.title'),
      onRefresh: _load,
      actions: [
        DsButton.icon(
          icon: Icons.refresh,
          semanticLabel: tr(context, 'credits.refresh'),
          onPressed: _loading ? null : _load,
        ),
      ],
      children: _body(),
    );
  }

  String _label(String raw) {
    if (raw.startsWith('openrouter:')) {
      return 'OpenRouter · ${raw.substring(11).split('/').last}';
    }
    if (raw.startsWith('stylist:')) {
      return '${tr(context, 'nav.stylist')} · ${raw.substring(8)}';
    }
    return 'BFL · $raw';
  }

  List<Widget> _body() {
    final ds = context.ds;
    final col = ds.colors;
    if (_loading && _costs == null) {
      return [
        Padding(
          padding: EdgeInsets.all(ds.space.xl),
          child: Center(child: CircularProgressIndicator(color: col.accent)),
        ),
      ];
    }
    if (_error != null) {
      return [
        DsError(
          message: '${tr(context, 'credits.loadError')}: $_error',
          retryLabel: tr(context, 'common.retry'),
          onRetry: _load,
        ),
      ];
    }
    final c = _costs!;
    final or = c.of('openrouter', _period);
    final bfl = c.of('bfl', _period);
    final sty = c.of('stylist', _period);
    final total = or.usd + bfl.usd + sty.usd;
    Widget row(IconData icon, String name, CostPeriod p, String unit) =>
        DsInfoRow(
          icon: icon,
          title: name,
          detail: tr(context, unit, {'n': '${p.count}'}),
          trailing: Text(usd(p.usd), style: ds.typo.mono),
        );
    return [
      DsSegment<String>(
        options: [
          ('today', tr(context, 'costs.today')),
          ('week', tr(context, 'costs.week')),
          ('month', tr(context, 'costs.month')),
          ('all', tr(context, 'costs.all')),
        ],
        value: _period,
        onChanged: (v) => setState(() => _period = v),
      ),
      SizedBox(height: ds.space.m),
      Text(usd(total), style: ds.typo.display),
      Text(
        tr(context, 'costs.total'),
        style: ds.typo.label.copyWith(color: col.textMuted),
      ),
      DsSectionTitle(tr(context, 'costs.byService')),
      row(Icons.auto_awesome, 'OpenRouter', or, 'costs.renders'),
      if (or.count > 0)
        DsInfoRow(
          icon: Icons.calculate_outlined,
          title: usd(or.usd / or.count),
          detail: tr(context, 'costs.perRender'),
        ),
      row(Icons.bolt_outlined, 'BFL', bfl, 'costs.renders'),
      row(Icons.forum_outlined, tr(context, 'nav.stylist'), sty, 'costs.calls'),
      if (c.openrouterLeft != null) ...[
        DsSectionTitle(tr(context, 'costs.openrouterAccount')),
        DsInfoRow(
          icon: Icons.account_balance_wallet_outlined,
          title: usd(c.openrouterLeft!),
          detail: tr(context, 'costs.openrouterLeft', {
            'used': usd(c.openrouterUsed ?? 0),
          }),
        ),
      ],
      if (c.stylistModels.isNotEmpty) ...[
        DsSectionTitle(tr(context, 'costs.stylistModels')),
        for (final (model, p) in c.stylistModels)
          row(Icons.memory, model, p, 'costs.calls'),
      ],
      if (c.recent.isNotEmpty) ...[
        DsSectionTitle(tr(context, 'costs.recent')),
        for (final r in c.recent)
          DsInfoRow(
            icon: r.label.startsWith('stylist:')
                ? Icons.forum_outlined
                : Icons.image_outlined,
            title: _label(r.label),
            detail: r.at,
            trailing: Text(usd(r.usd), style: ds.typo.mono),
          ),
      ],
      SizedBox(height: ds.space.m),
      Text(
        tr(context, 'costs.footnote'),
        style: ds.typo.label.copyWith(color: col.textMuted),
      ),
    ];
  }
}
