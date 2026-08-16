import 'package:flutter/material.dart';

import '../../app.dart';
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
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'credits.title')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
            tooltip: tr(context, 'credits.refresh'),
          ),
        ],
      ),
      body: RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _body() {
    if (_loading && _credits == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ListView(children: [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text('${tr(context, 'credits.loadError')}: $_error',
              textAlign: TextAlign.center),
        ),
      ]);
    }
    final c = _credits!;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (c.dryRun)
          Card(
            color: theme.colorScheme.tertiaryContainer,
            child: ListTile(
              leading: const Icon(Icons.science_outlined),
              title: Text(tr(context, 'credits.dryRun')),
              subtitle: Text(tr(context, 'credits.dryRunHint')),
            ),
          ),
        const SizedBox(height: 8),
        _sectionTitle(tr(context, 'credits.providerTitle')),
        Card(
          child: ListTile(
            leading: Icon(
                c.providerAvailable
                    ? Icons.account_balance_wallet_outlined
                    : Icons.help_outline,
                color: c.providerAvailable ? theme.colorScheme.primary : null),
            title: Text(c.providerAvailable
                ? tr(context, 'credits.balance', {
                    'credits': c.providerCredits!.toStringAsFixed(2),
                    'usd': (c.providerUsd ?? 0).toStringAsFixed(2),
                  })
                : tr(context, 'credits.providerUnknown')),
            subtitle: Text(c.providerAvailable
                ? tr(context, 'credits.providerHint')
                // The server's own words: "no endpoint configured",
                // "unreachable", "no recognisable balance" are different
                // problems with different fixes.
                : c.providerReason),
          ),
        ),
        const SizedBox(height: 16),
        _sectionTitle(tr(context, 'credits.spentTitle')),
        Card(
          child: Column(children: [
            // The spend leads, because it is the question. The call count is
            // context for it, not the headline.
            ListTile(
              leading: Icon(Icons.payments_outlined,
                  color: theme.colorScheme.primary),
              title: Text(tr(context, 'credits.balance', {
                'credits': c.creditsSpent.toStringAsFixed(2),
                'usd': c.usdSpent.toStringAsFixed(2),
              })),
              subtitle: Text(tr(context, 'credits.spentTotal')),
            ),
            ListTile(
              leading: const Icon(Icons.done_all),
              title: Text('${c.callsAccepted}'),
              subtitle: Text(tr(context, 'credits.accepted')),
            ),
            ListTile(
              leading: const Icon(Icons.calendar_month_outlined),
              title: Text(tr(context, 'credits.balance', {
                'credits': c.creditsLast30Days.toStringAsFixed(2),
                'usd': c.usdLast30Days.toStringAsFixed(2),
              })),
              subtitle: Text(tr(context, 'credits.last30', {
                'calls': '${c.callsLast30Days}',
              })),
            ),
            if (c.unpricedCalls > 0)
              ListTile(
                leading: const Icon(Icons.help_outline),
                title: Text('${c.unpricedCalls}'),
                subtitle: Text(tr(context, 'credits.unpriced')),
              ),
            if (c.callsRefused > 0)
              ListTile(
                leading: Icon(Icons.block, color: theme.colorScheme.error),
                title: Text('${c.callsRefused}'),
                subtitle: Text(tr(context, 'credits.refused')),
              ),
            if (c.lastCallAt != null)
              ListTile(
                leading: const Icon(Icons.schedule),
                title: Text(c.lastCallAt!),
                subtitle: Text(tr(context, 'credits.lastCall')),
              ),
          ]),
        ),
        if (c.byTier.isNotEmpty) ...[
          const SizedBox(height: 16),
          _sectionTitle(tr(context, 'credits.byTier')),
          Card(
            child: Column(children: [
              for (final e in (c.byTier.entries.toList()
                ..sort((a, b) => b.value.credits.compareTo(a.value.credits))))
                ListTile(
                  dense: true,
                  title: Text(e.key),
                  subtitle: Text(tr(context, 'credits.tierCalls',
                      {'calls': '${e.value.calls}'})),
                  trailing: Text(
                      e.value.credits.toStringAsFixed(2),
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
            ]),
          ),
        ],
        const SizedBox(height: 16),
        Text(tr(context, 'credits.footnote'),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6, left: 4),
        child: Text(t,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
      );
}
