import 'package:flutter_test/flutter_test.dart';
import 'package:snapy/i18n/i18n.dart';
import 'package:snapy/realcount/nudges.dart';
import 'package:snapy/realcount/rules.dart';

import 'helpers.dart';

void main() {
  setUpAll(useEnglish);
  const engine = NudgeEngine(RealCountRules.fallback);
  final t0 = DateTime(2026, 11, 15, 16, 0);
  String text(Nudge n) => tr(n.key, n.params);

  NudgeInput input({
    DateTime? now,
    NudgeTrigger trigger = NudgeTrigger.reelCounted,
    int sessionReels = 0,
    int sessionMinutes = 0,
    int opens = 0,
    double limit = 0,
    bool inCall = false,
    bool navigating = false,
    DateTime? focusUntil,
    DateTime? intentionEnds,
    bool voice = false,
    String? task,
  }) =>
      NudgeInput(
        now: now ?? t0,
        trigger: trigger,
        pkg: 'com.instagram.android',
        label: 'Instagram',
        shortVideo: true,
        sessionReels: sessionReels,
        sessionStartMs: t0.millisecondsSinceEpoch - 12 * 60000,
        sessionMinutes: sessionMinutes,
        opensLastHour: opens,
        limitFraction: limit,
        inCall: inCall,
        navigating: navigating,
        focusUntil: focusUntil,
        intentionEndsAt: intentionEnds,
        intentionId: intentionEnds == null ? null : 'browse',
        intentionMinutes: 10,
        voiceOn: voice,
        firstTaskTomorrow: task,
      );

  test('30 reels in one session: pulse + the reset card, once per session', () {
    final s = NudgeState();
    expect(engine.decide(input(sessionReels: 29, sessionMinutes: 11), s), isNull);
    final n = engine.decide(input(sessionReels: 30, sessionMinutes: 12), s)!;
    expect(n.kind, NudgeKind.sessionReels);
    expect(n.pulse, isTrue);
    expect(text(n), '30 Reels in 12 min. Keep going or take a 2-min reset?');
    expect(n.actions, ['keep_going', 'reset']);
    engine.shown(n, s, t0);
    // same session, after the gap: not again
    expect(engine.decide(input(now: t0.add(const Duration(minutes: 25)), sessionReels: 60, sessionMinutes: 37), s), isNull);
  });

  test('social app opened 10 times in an hour', () {
    final s = NudgeState();
    expect(engine.decide(input(trigger: NudgeTrigger.appOpened, opens: 9), s), isNull);
    final n = engine.decide(input(trigger: NudgeTrigger.appOpened, opens: 10), s)!;
    expect(n.kind, NudgeKind.frequentOpens);
    expect(text(n), 'You keep coming back to Instagram. Stuck on something? I can start a 25-min focus.');
    expect(n.actions.first, 'focus');
    // only on opening the app, not while scrolling
    expect(engine.decide(input(trigger: NudgeTrigger.reelCounted, opens: 12), NudgeState()), isNull);
  });

  test('daily soft limit: card, spoken when voice is on, opt-in pause before re-opening', () {
    final n = engine.decide(input(limit: 1.0, voice: true), NudgeState())!;
    expect(n.kind, NudgeKind.softLimit);
    expect(n.speak, isTrue);
    expect(engine.decide(input(limit: 1.0), NudgeState())!.speak, isFalse);
    expect(engine.pauseBeforeOpen(input(trigger: NudgeTrigger.appOpened, limit: 1.2), breakScreen: true), isTrue);
    expect(engine.pauseBeforeOpen(input(trigger: NudgeTrigger.appOpened, limit: 1.2), breakScreen: false), isFalse);
    expect(engine.pauseBeforeOpen(input(trigger: NudgeTrigger.appOpened, limit: 0.5), breakScreen: true), isFalse);
    expect(engine.pauseBeforeOpen(input(trigger: NudgeTrigger.appOpened, limit: 1.2, inCall: true), breakScreen: true), isFalse);
  });

  test('bedtime wind-down while scrolling, with tomorrow\'s first task, once per night', () {
    final late = DateTime(2026, 11, 15, 23, 10);
    expect(engine.decide(input(now: DateTime(2026, 11, 15, 22, 59)), NudgeState()), isNull);
    final s = NudgeState();
    final n = engine.decide(input(now: late, task: 'Send the deck'), s)!;
    expect(n.kind, NudgeKind.bedtime);
    expect(text(n), 'It’s getting late. Tomorrow starts with: Send the deck. Wind down?');
    engine.shown(n, s, late);
    // 00:40 is the same night
    expect(engine.decide(input(now: DateTime(2026, 11, 16, 0, 40)), s), isNull);
    expect(engine.nightKey(DateTime(2026, 11, 16, 0, 40)), '2026-11-15');
    // no reels scrolled (tick): no bedtime card
    expect(engine.decide(input(now: late, trigger: NudgeTrigger.tick), NudgeState()), isNull);
    expect(engine.isBedtime(DateTime(2026, 11, 16, 5, 59)), isTrue);
    expect(engine.isBedtime(DateTime(2026, 11, 16, 6, 0)), isFalse);
  });

  test('focus running and a social app opens: one tap to continue, exempt from the gap', () {
    final s = NudgeState()..lastShownMs = t0.millisecondsSinceEpoch;      // a nudge just showed
    final until = DateTime(2026, 11, 15, 16, 30);
    final n = engine.decide(input(trigger: NudgeTrigger.appOpened, focusUntil: until), s)!;
    expect(n.kind, NudgeKind.focusOpen);
    expect(text(n), 'You’re in focus until 4:30. Open Instagram anyway?');
    expect(n.actions, ['open_anyway', 'back_to_focus']);
    engine.shown(n, s, t0);
    expect(s.lastShownMs, t0.millisecondsSinceEpoch);                   // doesn't restart the gap
    expect(engine.decide(input(trigger: NudgeTrigger.appOpened, focusUntil: until), s), isNull);   // asked once per app
    expect(engine.decide(input(trigger: NudgeTrigger.appOpened, focusUntil: t0), NudgeState()), isNull); // focus over
  });

  test('intention reminder when its time is up', () {
    final n = engine.decide(input(trigger: NudgeTrigger.tick, intentionEnds: t0), NudgeState())!;
    expect(n.kind, NudgeKind.intentionDone);
    expect(text(n), 'Your 10 min of browsing is up. Wrap up?');
  });

  test('at most one nudge every 20 minutes', () {
    final s = NudgeState();
    final a = engine.decide(input(sessionReels: 30, sessionMinutes: 12), s)!;
    engine.shown(a, s, t0);
    expect(engine.decide(input(now: t0.add(const Duration(minutes: 19)), trigger: NudgeTrigger.appOpened, opens: 15), s), isNull);
    expect(engine.decide(input(now: t0.add(const Duration(minutes: 20)), trigger: NudgeTrigger.appOpened, opens: 15), s)?.kind,
        NudgeKind.frequentOpens);
  });

  test('never during calls or navigation', () {
    expect(engine.decide(input(sessionReels: 40, inCall: true), NudgeState()), isNull);
    expect(engine.decide(input(sessionReels: 40, navigating: true), NudgeState()), isNull);
    expect(engine.decide(input(trigger: NudgeTrigger.appOpened, focusUntil: t0.add(const Duration(hours: 1)), inCall: true), NudgeState()), isNull);
  });

  test('softer wording after two dismissals today; resets the next day', () {
    final s = NudgeState();
    engine.dismissed(s, t0);
    expect(engine.decide(input(sessionReels: 30, sessionMinutes: 12), s)!.soft, isFalse);
    engine.dismissed(s, t0);
    final n = engine.decide(input(sessionReels: 30, sessionMinutes: 12), s)!;
    expect(n.soft, isTrue);
    expect(n.key, 'nudge.session_reels_soft');
    expect(text(n), '30 reels so far. A 2-minute reset is here if you want it.');
    final tomorrow = t0.add(const Duration(days: 1));
    expect(engine.decide(input(now: tomorrow, sessionReels: 30), s)!.soft, isFalse);
  });

  test('priority: focus > intention > limit > session > opens > bedtime', () {
    final late = DateTime(2026, 11, 15, 23, 30);
    final all = input(now: late, trigger: NudgeTrigger.appOpened, sessionReels: 40, opens: 12, limit: 1.5,
        focusUntil: late.add(const Duration(minutes: 10)), intentionEnds: late);
    expect(engine.decide(all, NudgeState())!.kind, NudgeKind.focusOpen);
    final noFocus = input(now: late, trigger: NudgeTrigger.appOpened, sessionReels: 40, opens: 12, limit: 1.5);
    expect(engine.decide(noFocus, NudgeState())!.kind, NudgeKind.softLimit);
    final s = NudgeState()..fired.add('limit:com.instagram.android:2026-11-15');
    expect(engine.decide(noFocus, s)!.kind, NudgeKind.sessionReels);
  });

  test('config overrides thresholds', () {
    final e = NudgeEngine(RealCountRules.from({'nudges': {'session_reels': 10, 'min_gap_min': 5}}));
    expect(e.decide(input(sessionReels: 10, sessionMinutes: 3), NudgeState())?.kind, NudgeKind.sessionReels);
    expect(e.rules.i('nudges.opens_per_hour'), 10);                      // untouched keys keep defaults
  });

  test('state survives a JSON round trip and stays bounded', () {
    final s = NudgeState()..dismissals = 2..day = '2026-11-15'..lastShownMs = 5;
    for (var i = 0; i < NudgeEngine.maxFired + 20; i++) {
      engine.shown(Nudge(NudgeKind.sessionReels, 'k', const {}, const [], 'session:$i'), s, t0);
    }
    expect(s.fired.length, NudgeEngine.maxFired);
    final back = NudgeState.fromJson(s.toJson());
    expect(back.fired, s.fired);
    expect(back.dismissals, s.dismissals);
  });

  test('open tracker and reel session', () {
    final o = OpenTracker();
    for (var i = 0; i < 5; i++) {
      o.open('a', i * 1000);
    }
    o.open('a', 3600000 + 2500);
    expect(o.lastHour('a', 3600000 + 2500), 3);                          // the first three are over an hour old
    final r = ReelSession();
    const gap = 10 * 60000;
    r.reel(0, gap);
    r.reel(60000, gap);
    expect(r.count, 2);
    expect(r.minutes(), 1);
    r.reel(60000 + gap + 1, gap);                                        // a new session after the gap
    expect(r.count, 1);
    expect(r.active(60000 + gap + 2, gap), isTrue);
  });

  test('clock format matches the card', () {
    expect(clock(DateTime(2026, 1, 1, 16, 30)), '4:30');
    expect(clock(DateTime(2026, 1, 1, 0, 5)), '12:05');
  });
}
