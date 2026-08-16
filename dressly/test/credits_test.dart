import 'package:dressly/models/credits.dart';
import 'package:dressly/models/user.dart';
import 'package:flutter_test/flutter_test.dart';

/// The admin credits view reads two figures that must not be confused: what we
/// spent (ours, certain) and what the provider says is left (may not exist).
void main() {
  group('ApiCredits', () {
    test('reads both halves', () {
      final c = ApiCredits.fromJson({
        'dry_run': false,
        'provider': {'available': true, 'credits': 42.5, 'usd': 0.43},
        'spent': {
          'calls_total': 12,
          'calls_accepted': 10,
          'calls_last_30_days': 4,
          'credits_spent': 14.6,
          'usd_spent': 0.15,
          'credits_last_30_days': 5.6,
          'usd_last_30_days': 0.06,
          'priced_calls': 10,
          'unpriced_calls': 0,
          'by_tier': {
            'flex': {'calls': 7, 'credits': 9.8},
            'max': {'calls': 3, 'credits': 4.8},
          },
          'last_call_at': '2026-07-31 20:00:00',
        },
      });
      expect(c.providerAvailable, isTrue);
      expect(c.providerCredits, 42.5);
      // 1 credit = \$0.01 at the provider's published rate; the screen shows
      // both because a credit count alone says nothing.
      expect(c.providerUsd, 0.43);
      expect(c.callsAccepted, 10);
      expect(c.callsRefused, 2);
      expect(c.byTier['flex']!.calls, 7);
      // Measured from the provider's replies, not estimated from a rate card.
      expect(c.byTier['flex']!.credits, 9.8);
      expect(c.creditsSpent, 14.6);
      expect(c.usdSpent, 0.15);
    });

    test('an unavailable balance is not shown as zero', () {
      // Zero credits and "we cannot tell" look identical on a screen unless the
      // model keeps them apart.
      final c = ApiCredits.fromJson({
        'provider': {'available': false, 'reason': 'no balance endpoint'},
        'spent': {'calls_total': 3, 'calls_accepted': 3},
      });
      expect(c.providerAvailable, isFalse);
      expect(c.providerCredits, isNull);
      expect(c.providerReason, isNotEmpty);
    });

    test('refused calls never go negative', () {
      final c = ApiCredits.fromJson({
        'spent': {'calls_total': 0, 'calls_accepted': 5},
      });
      expect(c.callsRefused, 0);
    });

    test('an empty reply is readable', () {
      final c = ApiCredits.fromJson(const {});
      expect(c.callsTotal, 0);
      expect(c.byTier, isEmpty);
      expect(c.dryRun, isFalse);
      expect(c.creditsSpent, 0);
    });

    test('a server that has not been redeployed yet still renders', () {
      // The old shape was tier -> bare call count. Reading either means a
      // partial deploy shows a slightly poorer screen, not an empty one.
      final c = ApiCredits.fromJson({
        'spent': {'calls_accepted': 3, 'by_tier': {'flex': 3}},
      });
      expect(c.byTier['flex']!.calls, 3);
      expect(c.byTier['flex']!.credits, 0);
    });

    test('unpriced jobs are surfaced, not folded into the total', () {
      final c = ApiCredits.fromJson({
        'spent': {'calls_accepted': 5, 'priced_calls': 3, 'unpriced_calls': 2,
                  'credits_spent': 4.2},
      });
      expect(c.unpricedCalls, 2);
      expect(c.creditsSpent, 4.2);
    });
  });

  group('AppUser', () {
    test('carries the admin flag the server computed', () {
      expect(
          AppUser.fromJson({'id': 1, 'email': 'a@b.co', 'is_admin': true})
              .isAdmin,
          isTrue);
      // Older servers omit it; nobody becomes an admin by accident.
      expect(AppUser.fromJson({'id': 1, 'email': 'a@b.co'}).isAdmin, isFalse);
    });
  });
}
