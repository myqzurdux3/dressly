import 'package:flutter/material.dart';

import '../../app.dart';
import '../../design/ds.dart';
import '../../l10n/app_text.dart';
import '../../models/credits.dart';

/// What the image API has cost. Admin-only — the server refuses anyone else,
/// and the entry point is hidden for them.
///
/// The two figures are kept visually apart because they answer different
/// questions and only one of them is ours to know for certain.
class ApiCreditsScreen extends StatefulWidget {
  const ApiCreditsScreen({super.key});

  @override
  State<ApiCreditsScreen> createState() => _ApiCreditsScreenState();
}

class _ApiCreditsScreenState extends State<ApiCreditsScreen> {
  ApiCredits? _credits;
  Object? _error;
  bool _loading = true;

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
      final got = await svc.credits();
      if (!mounted) return;
      setState(() {
        _credits = got;
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

  @override
  Widget build(BuildContext context) {
    return DsSubPage(
      title: tr(context, 'credits.title'),
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

  List<Widget> _body() {
    final ds = context.ds;
    final col = ds.colors;
    if (_loading && _credits == null) {
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
    final c = _credits!;
    String money(double credits, double usd) => tr(context, 'credits.balance', {
      'credits': credits.toStringAsFixed(2),
      'usd': usd.toStringAsFixed(2),
    });
    return [
      if (c.dryRun)
        DsInfoRow(
          icon: Icons.science_outlined,
          title: tr(context, 'credits.dryRun'),
          detail: tr(context, 'credits.dryRunHint'),
          color: col.surfaceHigh,
        ),
      DsSectionTitle(tr(context, 'credits.providerTitle')),
      DsInfoRow(
        icon: c.providerAvailable
            ? Icons.account_balance_wallet_outlined
            : Icons.help_outline,
        title: c.providerAvailable
            ? money(c.providerCredits!, c.providerUsd ?? 0)
            : tr(context, 'credits.providerUnknown'),
        // The server's own words: "no endpoint configured", "unreachable",
        // "no recognisable balance" are different problems with different
        // fixes.
        detail: c.providerAvailable
            ? tr(context, 'credits.providerHint')
            : c.providerReason,
      ),
      DsSectionTitle(tr(context, 'credits.spentTitle')),
      // The spend leads, because it is the question. The call count is
      // context for it, not the headline.
      DsInfoRow(
        icon: Icons.payments_outlined,
        title: money(c.creditsSpent, c.usdSpent),
        detail: tr(context, 'credits.spentTotal'),
      ),
      DsInfoRow(
        icon: Icons.done_all,
        title: '${c.callsAccepted}',
        detail: tr(context, 'credits.accepted'),
      ),
      DsInfoRow(
        icon: Icons.calendar_month_outlined,
        title: money(c.creditsLast30Days, c.usdLast30Days),
        detail: tr(context, 'credits.last30', {
          'calls': '${c.callsLast30Days}',
        }),
      ),
      if (c.unpricedCalls > 0)
        DsInfoRow(
          icon: Icons.help_outline,
          title: '${c.unpricedCalls}',
          detail: tr(context, 'credits.unpriced'),
        ),
      if (c.callsRefused > 0)
        DsInfoRow(
          icon: Icons.block,
          danger: true,
          title: '${c.callsRefused}',
          detail: tr(context, 'credits.refused'),
        ),
      if (c.lastCallAt != null)
        DsInfoRow(
          icon: Icons.schedule,
          title: c.lastCallAt!,
          detail: tr(context, 'credits.lastCall'),
        ),
      if (c.byTier.isNotEmpty) ...[
        DsSectionTitle(tr(context, 'credits.byTier')),
        for (final e
            in (c.byTier.entries.toList()
              ..sort((a, b) => b.value.credits.compareTo(a.value.credits))))
          DsInfoRow(
            icon: Icons.bolt_outlined,
            title: e.key,
            detail: tr(context, 'credits.tierCalls', {
              'calls': '${e.value.calls}',
            }),
            trailing: Text(
              e.value.credits.toStringAsFixed(2),
              style: ds.typo.mono,
            ),
          ),
      ],
      SizedBox(height: ds.space.m),
      Text(
        tr(context, 'credits.footnote'),
        style: ds.typo.label.copyWith(color: col.textMuted),
      ),
    ];
  }
}
