/// The Real Count nudge engine — pure decision logic, no Flutter, no platform calls.
///
/// This Dart file is the REFERENCE implementation and is covered by test/nudges_test.dart.
/// The phone runs the Kotlin port in android/.../NudgeEngine.kt (the accessibility service
/// sees the events), which mirrors this file rule for rule: same inputs, same order of
/// checks, same i18n keys, same once-keys. Change both together.
///
/// Global rules: at most one nudge per `nudges.min_gap_min` (except guards the user asked
/// for: focus and intention reminders), never during calls or navigation, and softer
/// wording once the user has dismissed `nudges.soften_after_dismissals` nudges today.
/// Nudges are suggestions — nothing here blocks an app.
library;

import 'rules.dart';

enum NudgeTrigger { appOpened, reelCounted, tick }

enum NudgeKind { focusOpen, intentionDone, softLimit, sessionReels, frequentOpens, bedtime }

class NudgeInput {
  final DateTime now;
  final NudgeTrigger trigger;
  final String pkg;
  final String label;
  final bool shortVideo;          // the app has a reels/shorts feed
  final int sessionReels;         // reels in the current scroll session (all apps)
  final int sessionStartMs;       // identifies the session
  final int sessionMinutes;
  final int opensLastHour;        // this app
  final double limitFraction;     // max(app time / app limit, reels / reel limit); 0 = no limit set
  final bool inCall;
  final bool navigating;
  final DateTime? focusUntil;
  final DateTime? intentionEndsAt;
  final String? intentionId;
  final int intentionMinutes;
  final bool voiceOn;
  final String? firstTaskTomorrow;

  const NudgeInput({
    required this.now,
    required this.trigger,
    this.pkg = '',
    this.label = '',
    this.shortVideo = false,
    this.sessionReels = 0,
    this.sessionStartMs = 0,
    this.sessionMinutes = 0,
    this.opensLastHour = 0,
    this.limitFraction = 0,
    this.inCall = false,
    this.navigating = false,
    this.focusUntil,
    this.intentionEndsAt,
    this.intentionId,
    this.intentionMinutes = 0,
    this.voiceOn = false,
    this.firstTaskTomorrow,
  });
}

class Nudge {
  final NudgeKind kind;
  final String key;                  // i18n key of the card text
  final Map<String, String> params;
  final List<String> actions;        // action ids, also i18n keys under "action."
  final bool soft;
  final bool pulse;                  // pulse the chip
  final bool speak;                  // say it out loud (voice on)
  final String onceKey;
  const Nudge(this.kind, this.key, this.params, this.actions, this.onceKey,
      {this.soft = false, this.pulse = false, this.speak = false});

  @override
  String toString() => 'Nudge($kind, $key, $params)';
}

/// What the engine remembers between decisions (persisted by the host).
class NudgeState {
  int lastShownMs = 0;
  int dismissals = 0;
  String day = '';
  final Set<String> fired = <String>{};     // insertion-ordered, bounded

  Map<String, dynamic> toJson() => {'last': lastShownMs, 'dismissals': dismissals, 'day': day, 'fired': fired.toList()};

  static NudgeState fromJson(Map? j) {
    final s = NudgeState();
    if (j == null) return s;
    s.lastShownMs = (j['last'] as num?)?.toInt() ?? 0;
    s.dismissals = (j['dismissals'] as num?)?.toInt() ?? 0;
    s.day = (j['day'] ?? '').toString();
    s.fired.addAll(((j['fired'] as List?) ?? const []).map((e) => e.toString()));
    return s;
  }
}

class NudgeEngine {
  final RealCountRules rules;
  const NudgeEngine(this.rules);

  static const int maxFired = 100;

  Nudge? decide(NudgeInput i, NudgeState s) {
    _rollover(i.now, s);
    if (i.inCall || i.navigating) return null;                     // never during calls or navigation
    final soft = s.dismissals >= rules.i('nudges.soften_after_dismissals');
    String k(String base) => soft ? '${base}_soft' : base;
    final gapOk = i.now.millisecondsSinceEpoch - s.lastShownMs >= rules.i('nudges.min_gap_min') * 60000;
    Nudge? fresh(Nudge n) => s.fired.contains(n.onceKey) ? null : n;

    // 1. Focus guard (the user asked for it: exempt from the gap)
    final fu = i.focusUntil;
    if (i.trigger == NudgeTrigger.appOpened && fu != null && i.now.isBefore(fu)) {
      final n = fresh(Nudge(NudgeKind.focusOpen, k('nudge.focus_open'), {'until': clock(fu), 'app': i.label},
          const ['open_anyway', 'back_to_focus'], 'focus:${i.pkg}:${fu.millisecondsSinceEpoch}', soft: soft));
      if (n != null) return n;
    }
    // 2. Intention reminder (also user-requested)
    final ie = i.intentionEndsAt;
    if (ie != null && !i.now.isBefore(ie) && i.intentionId != null) {
      final n = fresh(Nudge(NudgeKind.intentionDone, k('nudge.intention_done_${i.intentionId}'),
          {'minutes': '${i.intentionMinutes}', 'app': i.label}, const ['wrap_up', 'dismiss'],
          'intent:${ie.millisecondsSinceEpoch}', soft: soft));
      if (n != null) return n;
    }
    if (!gapOk) return null;
    // 3. Daily soft limit reached
    if (i.limitFraction >= rules.d('chip.amber_at') && i.limitFraction > 0) {
      final n = fresh(Nudge(NudgeKind.softLimit, k('nudge.soft_limit'), {'app': i.label}, const ['reset', 'dismiss'],
          'limit:${i.pkg}:${dayKey(i.now)}', soft: soft, pulse: true, speak: i.voiceOn));
      if (n != null) return n;
    }
    // 4. A long scroll session
    if (i.shortVideo && i.sessionReels >= rules.i('nudges.session_reels')) {
      final n = fresh(Nudge(NudgeKind.sessionReels, k('nudge.session_reels'),
          {'n': '${i.sessionReels}', 'min': '${i.sessionMinutes}'}, const ['keep_going', 'reset'],
          'session:${i.sessionStartMs}', soft: soft, pulse: true));
      if (n != null) return n;
    }
    // 5. Coming back to the same app again and again
    if (i.trigger == NudgeTrigger.appOpened && i.opensLastHour >= rules.i('nudges.opens_per_hour')) {
      final n = fresh(Nudge(NudgeKind.frequentOpens, k('nudge.frequent_opens'),
          {'app': i.label, 'focus': '${rules.i('nudges.focus_min')}'}, const ['focus', 'dismiss'],
          'opens:${i.pkg}:${i.now.millisecondsSinceEpoch ~/ 3600000}', soft: soft));
      if (n != null) return n;
    }
    // 6. Bedtime wind-down while scrolling
    if (i.trigger != NudgeTrigger.tick && isBedtime(i.now)) {
      final task = i.firstTaskTomorrow;
      final has = task != null && task.isNotEmpty;
      final n = fresh(Nudge(NudgeKind.bedtime, k(has ? 'nudge.bedtime_task' : 'nudge.bedtime'), {if (has) 'task': task},
          const ['wind_down', 'dismiss'], 'bed:${nightKey(i.now)}', soft: soft));
      if (n != null) return n;
    }
    return null;
  }

  /// The opt-in 10-second pause before a social app opens again after its soft limit.
  bool pauseBeforeOpen(NudgeInput i, {required bool breakScreen}) =>
      breakScreen && i.trigger == NudgeTrigger.appOpened && i.limitFraction > 0 &&
      i.limitFraction >= rules.d('chip.amber_at') && !i.inCall && !i.navigating;

  void shown(Nudge n, NudgeState s, DateTime now) {
    _rollover(now, s);
    if (n.kind != NudgeKind.focusOpen && n.kind != NudgeKind.intentionDone) s.lastShownMs = now.millisecondsSinceEpoch;
    s.fired.add(n.onceKey);
    while (s.fired.length > maxFired) {
      s.fired.remove(s.fired.first);
    }
  }

  void dismissed(NudgeState s, DateTime now) {
    _rollover(now, s);
    s.dismissals++;
  }

  bool isBedtime(DateTime now) {
    final bed = rules.minutesOfDay('nudges.bedtime'), wake = rules.minutesOfDay('nudges.wake');
    final m = now.hour * 60 + now.minute;
    return bed > wake ? (m >= bed || m < wake) : (m >= bed && m < wake);
  }

  /// The night a bedtime belongs to (00:30 belongs to the previous evening).
  String nightKey(DateTime now) {
    final wake = rules.minutesOfDay('nudges.wake');
    final m = now.hour * 60 + now.minute;
    return dayKey(m < wake ? now.subtract(const Duration(days: 1)) : now);
  }

  void _rollover(DateTime now, NudgeState s) {
    final d = dayKey(now);
    if (s.day != d) {
      s.day = d;
      s.dismissals = 0;
    }
  }
}

/// Opens of each app in the last hour.
class OpenTracker {
  final Map<String, List<int>> _opens = {};

  void open(String pkg, int nowMs) => (_opens[pkg] ??= []).add(nowMs);

  int lastHour(String pkg, int nowMs) {
    final l = _opens[pkg];
    if (l == null) return 0;
    l.removeWhere((t) => nowMs - t > 3600000);
    return l.length;
  }
}

/// One scroll session across all short-video apps: ends after `nudges.session_gap_min` without a reel.
class ReelSession {
  int startMs = 0, lastMs = 0, count = 0;

  void reel(int nowMs, int gapMs) {
    if (count == 0 || nowMs - lastMs > gapMs) {
      startMs = nowMs;
      count = 0;
    }
    count++;
    lastMs = nowMs;
  }

  int minutes() => count == 0 ? 0 : ((lastMs - startMs) / 60000).ceil().clamp(1, 1 << 30);
  bool active(int nowMs, int gapMs) => count > 0 && nowMs - lastMs <= gapMs;
}

String two(int n) => n.toString().padLeft(2, '0');
String dayKey(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';

/// "4:30" style (12-hour, no am/pm — the card says "until 4:30").
String clock(DateTime d) => '${d.hour % 12 == 0 ? 12 : d.hour % 12}:${two(d.minute)}';
