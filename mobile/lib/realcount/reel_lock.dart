// Reel limits and the hard lock (docs/ANDROID_NEXT_PLAN.md §3) — the pure state machine.
//
// Mirrored 1:1 in Kotlin: android/app/src/main/kotlin/live/snapy/app/ReelLock.kt
// (ReelLockLogic + BounceTracker), the same way CounterLogic.kt mirrors chip_logic.dart and
// NudgeEngine.kt mirrors nudges.dart. Change both together; test/reel_lock_test.dart pins the
// behaviour both must follow.
//
// Per app: {limit, mode}. limit 0 = off. mode "soft" (nudge only) or "hard" (bounce the
// short-video feed with Back). The day's state (grants of "5 more", whether the 80% deflector
// was shown) resets at local midnight; the reel count itself comes from the day's Real Count.

/// Tunables (core config `android.realcount.reel_lock` may override each key).
class ReelLockRules {
  final int extraReels; // "5 more"
  final int extraPerDay; // how many "5 more" grants per app per day
  final int breathS; // the breath before a grant
  final double deflectAt; // fraction of the limit for the dopamine deflector
  final int deflectBubbleMs; // the breathing bubble
  final int maxBacks; // Backs before escalating (launch the app's main screen / Home)
  final int bounceWindowMs; // Backs closer than this count towards escalation
  final int bounceLatencyMs; // budget from feed detection to Back

  const ReelLockRules({
    this.extraReels = 5,
    this.extraPerDay = 1,
    this.breathS = 10,
    this.deflectAt = 0.8,
    this.deflectBubbleMs = 3000,
    this.maxBacks = 2,
    this.bounceWindowMs = 2500,
    this.bounceLatencyMs = 150,
  });

  factory ReelLockRules.fromJson(Map<String, dynamic>? j) {
    j ??= const {};
    const d = ReelLockRules();
    int i(String k, int def) => (j![k] as num?)?.toInt() ?? def;
    return ReelLockRules(
      extraReels: i('extra_reels', d.extraReels),
      extraPerDay: i('extra_per_day', d.extraPerDay),
      breathS: i('breath_s', d.breathS),
      deflectAt: (j['deflect_at'] as num?)?.toDouble() ?? d.deflectAt,
      deflectBubbleMs: i('deflect_bubble_ms', d.deflectBubbleMs),
      maxBacks: i('max_backs', d.maxBacks),
      bounceWindowMs: i('bounce_window_ms', d.bounceWindowMs),
      bounceLatencyMs: i('bounce_latency_ms', d.bounceLatencyMs),
    );
  }
}

class ReelLimitConfig {
  final int limit;
  final String mode; // soft | hard
  const ReelLimitConfig({this.limit = 0, this.mode = 'soft'});

  bool get hard => mode == 'hard';
  bool get off => limit <= 0;

  factory ReelLimitConfig.fromJson(Map<String, dynamic>? j) => ReelLimitConfig(
        limit: ((j?['limit'] as num?)?.toInt() ?? 0).clamp(0, 100000),
        mode: j?['mode'] == 'hard' ? 'hard' : 'soft',
      );

  Map<String, dynamic> toJson() => {'limit': limit, 'mode': mode};
}

/// Lock states (the §9 `state` field): off | ok | near | over (soft, at/over the limit) |
/// locked (hard, at/over the allowance) | unlocked (hard, inside a "5 more" grant).
class ReelLockState {
  static const off = 'off', ok = 'ok', near = 'near', over = 'over', locked = 'locked', unlocked = 'unlocked';
}

/// One local day of lock bookkeeping, for every app.
class ReelDay {
  String day; // yyyy-mm-dd (local)
  final Map<String, int> grants; // package -> "5 more" grants used today
  final Set<String> deflected; // packages that got today's 80% bubble

  ReelDay(this.day, [Map<String, int>? grants, Set<String>? deflected])
      : grants = grants ?? {},
        deflected = deflected ?? {};

  factory ReelDay.fromJson(Map<String, dynamic>? j) => ReelDay(
        '${j?['day'] ?? ''}',
        {for (final e in ((j?['grants'] as Map?) ?? const {}).entries) '${e.key}': (e.value as num).toInt()},
        {for (final p in (j?['deflected'] as List?) ?? const []) '$p'},
      );

  Map<String, dynamic> toJson() => {'day': day, 'grants': grants, 'deflected': [...deflected]..sort()};
}

class ReelLock {
  final ReelLockRules rules;
  const ReelLock([this.rules = const ReelLockRules()]);

  static String dayKey(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  /// Midnight reset: a new local day starts with no grants and no deflector shown.
  ReelDay rollover(ReelDay d, DateTime now) {
    final k = dayKey(now);
    if (d.day == k) return d;
    return ReelDay(k);
  }

  /// Reels allowed today (the limit plus granted "5 more").
  int allowance(ReelLimitConfig c, ReelDay d, String pkg) => c.limit + (d.grants[pkg] ?? 0) * rules.extraReels;

  String state(ReelLimitConfig c, int used, ReelDay d, String pkg) {
    if (c.off) return ReelLockState.off;
    final grants = d.grants[pkg] ?? 0;
    if (c.hard) {
      if (used >= allowance(c, d, pkg)) return ReelLockState.locked;
      if (grants > 0 && used >= c.limit) return ReelLockState.unlocked;
    } else if (used >= c.limit) {
      return ReelLockState.over;
    }
    if (used >= nearAt(c)) return ReelLockState.near;
    return ReelLockState.ok;
  }

  /// The count at which the deflector shows (80% of the limit, at least 1).
  int nearAt(ReelLimitConfig c) {
    final n = (c.limit * rules.deflectAt).ceil();
    return n < 1 ? 1 : n;
  }

  bool isLocked(ReelLimitConfig c, int used, ReelDay d, String pkg) => state(c, used, d, pkg) == ReelLockState.locked;

  /// The 80% dopamine deflector: once per app per day, between 80% and the limit (any mode).
  /// Marks it shown when it returns true.
  bool takeDeflector(ReelLimitConfig c, int used, ReelDay d, String pkg) {
    if (c.off || d.deflected.contains(pkg)) return false;
    if (used < nearAt(c) || used >= c.limit) return false;
    d.deflected.add(pkg);
    return true;
  }

  /// "5 more" is offered only while locked and only [ReelLockRules.extraPerDay] times a day.
  bool canGrant(ReelLimitConfig c, int used, ReelDay d, String pkg) =>
      isLocked(c, used, d, pkg) && (d.grants[pkg] ?? 0) < rules.extraPerDay;

  /// After the breath (the caller waits [ReelLockRules.breathS] seconds): grant "5 more".
  bool grant(ReelLimitConfig c, int used, ReelDay d, String pkg, {required int breathedMs}) {
    if (!canGrant(c, used, d, pkg) || breathedMs < rules.breathS * 1000) return false;
    d.grants[pkg] = (d.grants[pkg] ?? 0) + 1;
    return true;
  }
}

enum BounceAction { none, back, escalate }

/// While the feed of a locked app is on screen: Back, and after [ReelLockRules.maxBacks]
/// Backs inside the window with the feed still showing, escalate (open the app's main screen,
/// else Home). Re-entering the feed later starts a new run (persistent bounce).
class BounceTracker {
  final ReelLockRules rules;
  final List<int> _backs = [];
  BounceTracker([this.rules = const ReelLockRules()]);

  BounceAction onFeedVisible(int nowMs, {required bool locked}) {
    if (!locked) {
      _backs.clear();
      return BounceAction.none;
    }
    _backs.removeWhere((t) => nowMs - t > rules.bounceWindowMs);
    if (_backs.length >= rules.maxBacks) {
      _backs.clear();
      return BounceAction.escalate;
    }
    _backs.add(nowMs);
    return BounceAction.back;
  }

  /// Left the feed (another screen of the app / another app): the next entry starts over.
  void reset() => _backs.clear();

  int get recentBacks => _backs.length;
}

/// The §3 lock capsule text (Kotlin: Strings key `reel_lock.capsule`).
String lockCapsuleText(String app, String kind, int n, int limit) =>
    '🔒 $app $kind locked for today ($n/$limit). Everything else in $app still works.';

String deflectorText(int n, String kind) => '$n ${kind.toLowerCase()} so far. Take a breath.';
