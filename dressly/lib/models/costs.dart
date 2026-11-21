/// What generations cost, in USD, from GET /admin/costs.
class CostPeriod {
  const CostPeriod(this.count, this.usd);
  final int count;
  final double usd;

  factory CostPeriod.fromJson(Map? j) => CostPeriod(
    ((j?['count'] ?? 0) as num).toInt(),
    ((j?['usd'] ?? 0) as num).toDouble(),
  );
}

class CostLine {
  const CostLine(this.at, this.label, this.usd);
  final String at;
  final String label;
  final double usd;
}

class GenerationCosts {
  GenerationCosts({
    required this.byProvider,
    required this.stylistModels,
    required this.recent,
    this.openrouterLeft,
    this.openrouterUsed,
  });

  /// provider ('openrouter' | 'bfl' | 'stylist') -> period
  /// ('today' | 'week' | 'month' | 'all') -> totals.
  final Map<String, Map<String, CostPeriod>> byProvider;
  final List<(String, CostPeriod)> stylistModels;
  final List<CostLine> recent;

  /// The OpenRouter account, when the server could ask it.
  final double? openrouterLeft;
  final double? openrouterUsed;

  CostPeriod of(String provider, String period) =>
      byProvider[provider]?[period] ?? const CostPeriod(0, 0);

  factory GenerationCosts.fromJson(Map<String, dynamic> j) {
    Map<String, CostPeriod> periods(Object? v) => {
      for (final e in ((v as Map?) ?? {}).entries)
        e.key as String: CostPeriod.fromJson(e.value as Map?),
    };
    final bal = j['openrouter_balance'] as Map?;
    return GenerationCosts(
      byProvider: {
        for (final p in const ['openrouter', 'bfl', 'stylist'])
          p: periods(j[p]),
      },
      stylistModels: [
        for (final m in (j['stylist_models'] as List? ?? []))
          ((m as Map)['model'] as String, CostPeriod.fromJson(m)),
      ],
      recent: [
        for (final r in (j['recent'] as List? ?? []))
          CostLine(
            ((r as Map)['at'] ?? '') as String,
            (r['label'] ?? '') as String,
            ((r['usd'] ?? 0) as num).toDouble(),
          ),
      ],
      openrouterLeft: (bal?['left'] as num?)?.toDouble(),
      openrouterUsed: (bal?['used'] as num?)?.toDouble(),
    );
  }
}
