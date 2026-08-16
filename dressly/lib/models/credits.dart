/// One tier's share of the spend.
class TierSpend {
  const TierSpend({required this.calls, required this.credits});

  final int calls;
  final double credits;

  /// An older server sent a bare call count per tier; read either shape rather
  /// than showing nothing after a partial deploy.
  factory TierSpend.fromJson(Object? raw) {
    if (raw is num) return TierSpend(calls: raw.toInt(), credits: 0);
    final m = (raw as Map?)?.cast<String, dynamic>() ?? const {};
    return TierSpend(
      calls: (m['calls'] as num?)?.toInt() ?? 0,
      credits: (m['credits'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// What the paid image API has cost, and what the provider says is left.
///
/// Two figures on purpose. The spend is counted by our own server and is always
/// true; the balance depends on a provider endpoint that may not exist, so it
/// carries its own availability rather than a zero that would read as "broke".
class ApiCredits {
  ApiCredits({
    required this.callsTotal,
    required this.callsAccepted,
    required this.callsLast30Days,
    required this.byTier,
    required this.dryRun,
    this.creditsSpent = 0,
    this.usdSpent = 0,
    this.creditsLast30Days = 0,
    this.usdLast30Days = 0,
    this.unpricedCalls = 0,
    this.lastCallAt,
    this.providerAvailable = false,
    this.providerCredits,
    this.providerUsd,
    this.providerReason = '',
  });

  /// Every job submitted, including the ones the provider refused.
  final int callsTotal;

  /// The ones it accepted — the number that maps to a bill.
  final int callsAccepted;
  final int callsLast30Days;

  /// tier -> (calls, credits), so an expensive tier is visible on its own.
  final Map<String, TierSpend> byTier;

  /// What the provider said the accepted jobs cost, in credits and at its
  /// published rate. Measured, not estimated from a price list.
  final double creditsSpent;
  final double usdSpent;
  final double creditsLast30Days;
  final double usdLast30Days;

  /// Accepted calls that came back without a cost. Shown when it is not zero:
  /// a total that quietly drops them reads as cheaper than it was.
  final int unpricedCalls;

  /// No API key: the server renders placeholders and bills nothing.
  final bool dryRun;

  final String? lastCallAt;

  final bool providerAvailable;
  final double? providerCredits;

  /// The balance at the provider's published rate (1 credit = $0.01). A
  /// four-figure credit count means nothing on its own.
  final double? providerUsd;

  final String providerReason;

  /// The ones that were refused — worth showing when it is not zero, because a
  /// run of refusals usually means a quota or a key problem.
  int get callsRefused => (callsTotal - callsAccepted).clamp(0, callsTotal);

  factory ApiCredits.fromJson(Map<String, dynamic> j) {
    final spent = (j['spent'] as Map?)?.cast<String, dynamic>() ?? const {};
    final provider = (j['provider'] as Map?)?.cast<String, dynamic>() ?? const {};
    final tiers = (spent['by_tier'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ApiCredits(
      callsTotal: (spent['calls_total'] as num?)?.toInt() ?? 0,
      callsAccepted: (spent['calls_accepted'] as num?)?.toInt() ?? 0,
      callsLast30Days: (spent['calls_last_30_days'] as num?)?.toInt() ?? 0,
      byTier: {
        for (final e in tiers.entries)
          e.key: TierSpend.fromJson(e.value),
      },
      creditsSpent: (spent['credits_spent'] as num?)?.toDouble() ?? 0,
      usdSpent: (spent['usd_spent'] as num?)?.toDouble() ?? 0,
      creditsLast30Days:
          (spent['credits_last_30_days'] as num?)?.toDouble() ?? 0,
      usdLast30Days: (spent['usd_last_30_days'] as num?)?.toDouble() ?? 0,
      unpricedCalls: (spent['unpriced_calls'] as num?)?.toInt() ?? 0,
      lastCallAt: spent['last_call_at'] as String?,
      dryRun: j['dry_run'] == true,
      providerAvailable: provider['available'] == true,
      providerCredits: (provider['credits'] as num?)?.toDouble(),
      providerUsd: (provider['usd'] as num?)?.toDouble(),
      providerReason: (provider['reason'] ?? '') as String,
    );
  }
}
