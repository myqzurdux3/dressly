import 'package:flutter/material.dart';

import '../../app.dart';
import '../../design/ds.dart';
import '../../l10n/app_text.dart';
import '../../models/costs.dart';
import '../../models/credits.dart';

/// What the paid services have cost, in dollars: OpenRouter renders, the BFL
/// cascade and the stylist, over a chosen period; the providers' balances;
/// then the latest calls. Admin-only: the server refuses anyone else.
///
/// It also carries what the former "Image API credits" page showed (the BFL
/// balance, refused submissions, spend by tier), so one page answers "what
/// has this cost".
class CostsScreen extends StatefulWidget {
  const CostsScreen({super.key});

  @override
  State<CostsScreen> createState() => _CostsScreenState();
}

class _CostsScreenState extends State<CostsScreen> {
  GenerationCosts? _costs;

  /// The BFL side, from /admin/credits; null if that call failed.
  ApiCredits? _bfl;
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
      final results = await Future.wait<Object?>([
        svc.costs(),
        svc.credits().then<ApiCredits?>((v) => v).catchError((_) => null),
      ]);
      if (!mounted) return;
      setState(() {
        _costs = results[0] as GenerationCosts;
        _bfl = results[1] as ApiCredits?;
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

  bool get _fr => Localizations.localeOf(context).languageCode == 'fr';

  /// [v] with [decimals] places in the active locale: thousands grouped by
  /// the locale ("1,234.50" / "1 234,50").
  String _num(double v, int decimals) {
    final fixed = v.abs().toStringAsFixed(decimals);
    final dot = fixed.indexOf('.');
    final whole = MaterialLocalizations.of(
      context,
    ).formatDecimal(int.parse(dot < 0 ? fixed : fixed.substring(0, dot)));
    final frac = dot < 0 ? '' : '${_fr ? ',' : '.'}${fixed.substring(dot + 1)}';
    return '${v < 0 ? '-' : ''}$whole$frac';
  }

  /// A dollar amount; three decimals under a dollar so fractions of a cent
  /// still show.
  String usd(double v) {
    final n = _num(v, v.abs() < 1 ? 3 : 2);
    return _fr ? '$n \$' : '\$$n';
  }

  /// A server timestamp ("2026-11-22 14:05:00", UTC) as a localized medium
  /// date and time. Falls back to the raw text if it does not parse.
  String _when(String raw) {
    final dt = DateTime.tryParse(raw);
    if (dt == null) return raw;
    final loc = MaterialLocalizations.of(context);
    final time = loc.formatTimeOfDay(
      TimeOfDay.fromDateTime(dt),
      alwaysUse24HourFormat: true,
    );
    return '${loc.formatMediumDate(dt)} · $time';
  }

  /// "flex" -> "Flex"; tier ids come lowercase from the server.
  static String _tier(String id) =>
      id.isEmpty ? id : '${id[0].toUpperCase()}${id.substring(1)}';

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

  /// The BFL account: balance, dry run, refused submissions, spend by tier.
  List<Widget> _bflSection() {
    final b = _bfl;
    if (b == null) return const [];
    final ds = context.ds;
    final col = ds.colors;
    return [
      DsSectionTitle(tr(context, 'costs.bflAccount')),
      if (b.dryRun)
        DsInfoRow(
          icon: Icons.science_outlined,
          title: tr(context, 'credits.dryRun'),
          detail: tr(context, 'credits.dryRunHint'),
          color: col.surfaceHigh,
        ),
      DsInfoRow(
        icon: b.providerAvailable
            ? Icons.account_balance_wallet_outlined
            : Icons.help_outline,
        title: b.providerAvailable
            ? tr(context, 'credits.balance', {
                'credits': _num(b.providerCredits!, 2),
                'usd': _num(b.providerUsd ?? 0, 2),
              })
            : tr(context, 'credits.providerUnknown'),
        detail: b.providerAvailable
            ? tr(context, 'credits.providerHint')
            : b.providerReason,
      ),
      if (b.callsRefused > 0)
        DsInfoRow(
          icon: Icons.block,
          danger: true,
          title: '${b.callsRefused}',
          detail: tr(context, 'credits.refused'),
        ),
      for (final e
          in (b.byTier.entries.toList()
            ..sort((x, y) => y.value.credits.compareTo(x.value.credits))))
        DsInfoRow(
          icon: Icons.bolt_outlined,
          title: _tier(e.key),
          detail: tr(context, 'credits.tierCalls', {
            'calls': '${e.value.calls}',
          }),
          trailing: Text(usd(e.value.credits / 100), style: ds.typo.mono),
        ),
    ];
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
      ..._bflSection(),
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
            detail: _when(r.at),
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
