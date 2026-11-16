// The reel-limit state machine (lib/realcount/reel_lock.dart, mirrored in ReelLock.kt).
import 'package:flutter_test/flutter_test.dart';
import 'package:snapy/realcount/reel_lock.dart';

void main() {
  const lock = ReelLock();
  const hard = ReelLimitConfig(limit: 20, mode: 'hard');
  const soft = ReelLimitConfig(limit: 20, mode: 'soft');
  ReelDay today() => ReelDay('2026-11-16');

  group('states', () {
    test('off when no limit is set (limits are opt-in)', () {
      expect(lock.state(const ReelLimitConfig(), 500, today(), 'ig'), ReelLockState.off);
      expect(ReelLimitConfig.fromJson(null).off, isTrue);
      expect(ReelLimitConfig.fromJson({'limit': 10}).mode, 'soft', reason: 'soft is the default mode');
    });

    test('soft: ok -> near (80%) -> over, never locked', () {
      expect(lock.state(soft, 15, today(), 'ig'), ReelLockState.ok);
      expect(lock.state(soft, 16, today(), 'ig'), ReelLockState.near);
      expect(lock.state(soft, 20, today(), 'ig'), ReelLockState.over);
      expect(lock.state(soft, 90, today(), 'ig'), ReelLockState.over);
      expect(lock.isLocked(soft, 90, today(), 'ig'), isFalse);
    });

    test('hard: near at 80%, locked at the limit', () {
      expect(lock.state(hard, 15, today(), 'ig'), ReelLockState.ok);
      expect(lock.state(hard, 16, today(), 'ig'), ReelLockState.near);
      expect(lock.state(hard, 20, today(), 'ig'), ReelLockState.locked);
      expect(lock.isLocked(hard, 25, today(), 'ig'), isTrue);
    });

    test('limits are per app', () {
      final d = today();
      expect(lock.isLocked(hard, 20, d, 'ig'), isTrue);
      expect(lock.state(hard, 3, d, 'yt'), ReelLockState.ok);
    });
  });

  group('"5 more"', () {
    test('only while locked, after the 10-second breath, once a day', () {
      final d = today();
      expect(lock.canGrant(hard, 10, d, 'ig'), isFalse, reason: 'not locked yet');
      expect(lock.grant(hard, 20, d, 'ig', breathedMs: 4000), isFalse, reason: 'breath too short');
      expect(lock.grant(hard, 20, d, 'ig', breathedMs: 10000), isTrue);
      expect(lock.state(hard, 20, d, 'ig'), ReelLockState.unlocked);
      expect(lock.state(hard, 24, d, 'ig'), ReelLockState.unlocked);
      expect(lock.state(hard, 25, d, 'ig'), ReelLockState.locked, reason: 'the 5 extra are used up');
      expect(lock.canGrant(hard, 25, d, 'ig'), isFalse, reason: 'once a day');
      expect(lock.grant(hard, 25, d, 'ig', breathedMs: 20000), isFalse);
    });

    test('configurable count and grants per day', () {
      const l2 = ReelLock(ReelLockRules(extraReels: 3, extraPerDay: 2));
      final d = today();
      expect(l2.grant(hard, 20, d, 'ig', breathedMs: 10000), isTrue);
      expect(l2.allowance(hard, d, 'ig'), 23);
      expect(l2.grant(hard, 23, d, 'ig', breathedMs: 10000), isTrue);
      expect(l2.allowance(hard, d, 'ig'), 26);
      expect(l2.canGrant(hard, 26, d, 'ig'), isFalse);
    });
  });

  group('dopamine deflector (80%)', () {
    test('once per app per day, between 80% and the limit', () {
      final d = today();
      expect(lock.takeDeflector(hard, 15, d, 'ig'), isFalse);
      expect(lock.takeDeflector(hard, 16, d, 'ig'), isTrue);
      expect(lock.takeDeflector(hard, 17, d, 'ig'), isFalse, reason: 'already shown today');
      expect(lock.takeDeflector(soft, 16, d, 'yt'), isTrue, reason: 'soft mode too');
      expect(lock.takeDeflector(hard, 20, today(), 'ig'), isFalse, reason: 'at the limit the lock takes over');
    });

    test('small limits: at least the first reel', () {
      expect(lock.nearAt(const ReelLimitConfig(limit: 1, mode: 'hard')), 1);
      expect(lock.nearAt(const ReelLimitConfig(limit: 5, mode: 'hard')), 4);
    });
  });

  group('midnight reset', () {
    test('a new day clears grants and the deflector', () {
      final d = today();
      lock.grant(hard, 20, d, 'ig', breathedMs: 10000);
      d.deflected.add('ig');
      final same = lock.rollover(d, DateTime(2026, 11, 16, 23, 59));
      expect(identical(same, d), isTrue);
      final next = lock.rollover(d, DateTime(2026, 11, 17, 0, 0));
      expect(next.day, '2026-11-17');
      expect(next.grants, isEmpty);
      expect(next.deflected, isEmpty);
      // the reel count is per day too (Real Count's day file), so 0 reels -> ok again
      expect(lock.state(hard, 0, next, 'ig'), ReelLockState.ok);
    });

    test('day state round-trips through JSON (RcPrefs s_rl_day)', () {
      final d = ReelDay('2026-11-16', {'ig': 1}, {'yt'});
      final back = ReelDay.fromJson(d.toJson());
      expect(back.day, '2026-11-16');
      expect(back.grants['ig'], 1);
      expect(back.deflected, {'yt'});
    });
  });

  group('bounce', () {
    test('Back while locked; escalate after 2 Backs inside the window; reset on leaving', () {
      final b = BounceTracker();
      expect(b.onFeedVisible(0, locked: true), BounceAction.back);
      expect(b.onFeedVisible(450, locked: true), BounceAction.back);
      expect(b.onFeedVisible(900, locked: true), BounceAction.escalate);
      // persistent bounce on re-entry later
      expect(b.onFeedVisible(60000, locked: true), BounceAction.back);
      b.reset();
      expect(b.onFeedVisible(60100, locked: true), BounceAction.back);
      expect(b.onFeedVisible(60200, locked: false), BounceAction.none);
    });

    test('Backs far apart never escalate', () {
      final b = BounceTracker();
      for (var t = 0; t < 30000; t += 5000) {
        expect(b.onFeedVisible(t, locked: true), BounceAction.back);
      }
    });

    test('the latency budget is 150 ms', () {
      expect(const ReelLockRules().bounceLatencyMs, 150);
      expect(ReelLockRules.fromJson({'max_backs': 3}).maxBacks, 3);
    });
  });

  test('copy (§3)', () {
    expect(lockCapsuleText('Instagram', 'Reels', 20, 20), '🔒 Instagram Reels locked for today (20/20). Everything else in Instagram still works.');
    expect(deflectorText(16, 'Reels'), '16 reels so far. Take a breath.');
  });
}
