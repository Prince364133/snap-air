import 'package:flutter_test/flutter_test.dart';
import 'package:snapy/i18n/i18n.dart';
import 'package:snapy/realcount/chip_logic.dart';
import 'package:snapy/realcount/rules.dart';

import 'helpers.dart';

void main() {
  setUpAll(useEnglish);
  const rules = RealCountRules.fallback;

  test('chip text: screen time today + total reels', () {
    expect(tr('chip.text', {'time': formatDuration((5 * 60 + 16) * 60000), 'reels': '42'}), '5h 16m · ▶ 42');
    expect(formatDuration(59 * 60000), '59m');
    expect(tr('chip.paused_time', {'time': '1h 0m'}), '1h 0m · counter paused');
    expect(tr('chip.paused'), 'Counter paused');                 // the shared key (all languages)
  });

  test('amber at the soft limit with a ring filling toward it — never red', () {
    expect(limitFraction(usedMs: 15 * 60000, limitMin: 30), 0.5);
    expect(limitFraction(reels: 45, reelLimit: 30, usedMs: 10 * 60000, limitMin: 60), 1.5);
    expect(limitFraction(), 0);
    expect(chipTone(fraction: 0.99, amberAt: 1), ChipTone.normal);
    expect(chipTone(fraction: 1.0, amberAt: 1), ChipTone.amber);
    expect(chipTone(fraction: 0, amberAt: 1, bedtime: true), ChipTone.dim);
    expect(chipTone(fraction: 2, amberAt: 1, paused: true), ChipTone.paused);
    expect(ChipTone.values.map((e) => e.name), isNot(contains('red')));
    expect(ringProgress(0.4), 0.4);
    expect(ringProgress(3), 1.0);
  });

  group('placement', () {
    test('centred on a punch-hole camera, with a gap for the lens', () {
      final p = placeChip(screenW: 1080, statusBarH: 100, chipW: 300, chipH: 70,
          cutouts: const [Rect4(510, 30, 570, 90)], gapPadPx: 20);
      expect(p.cameraGap, 100);                         // 60 px hole + 2 × 20 px
      expect(p.x + (300 + p.cameraGap) ~/ 2, 540);      // chip centre = camera centre
      expect(p.height, 80);                             // grows to cover the 60 px hole + padding
      expect(p.y + p.height ~/ 2, 60);
    });

    test('corner punch-hole: centred on it, kept on screen', () {
      final p = placeChip(screenW: 1080, statusBarH: 100, chipW: 300, chipH: 70, cutouts: const [Rect4(40, 30, 100, 90)], gapPadPx: 20);
      expect(p.x, 0);
    });

    test('no cut-out: top-centre in the status bar row', () {
      final p = placeChip(screenW: 1080, statusBarH: 90, chipW: 300, chipH: 70);
      expect(p, isA<ChipPlacement>());
      expect(p.x, 390);
      expect(p.y, 10);
      expect(p.cameraGap, 0);
    });

    test('wide notch: just below it', () {
      final p = placeChip(screenW: 1080, statusBarH: 100, chipW: 300, chipH: 70, cutouts: const [Rect4(300, 0, 780, 100)], gapPadPx: 10);
      expect(p.y, 110);
      expect(p.cameraGap, 0);
    });

    test('where the user dragged it wins, clamped to the screen', () {
      final p = placeChip(screenW: 1080, statusBarH: 100, chipW: 300, chipH: 70, cutouts: const [Rect4(510, 30, 570, 90)], saved: (900, 400));
      expect(p.x, 780);
      expect(p.y, 400);
    });

    test('bottom cut-outs are ignored', () {
      final p = placeChip(screenW: 1080, statusBarH: 100, chipW: 300, chipH: 70, cutouts: const [Rect4(500, 2200, 580, 2280)]);
      expect(p.cameraGap, 0);
      expect(p.x, 390);
    });
  });

  test('auto-hide over full-screen video, games, the lock screen and calls', () {
    expect(chipHidden(const HideSignals()), isFalse);
    expect(chipHidden(const HideSignals(fullscreen: true)), isTrue);
    expect(chipHidden(const HideSignals(game: true)), isTrue);
    expect(chipHidden(const HideSignals(locked: true)), isTrue);
    expect(chipHidden(const HideSignals(inCall: true)), isTrue);
    expect(chipHidden(const HideSignals(hiddenToday: true)), isTrue);
    expect(chipHidden(const HideSignals(fullscreen: true), listening: true), isFalse);  // voice feedback still shows
    expect(chipHidden(const HideSignals(locked: true), listening: true), isTrue);
  });

  test('health: "counter paused" when events stop, clears on the next event', () {
    const stale = 180000;
    expect(counterPaused(nowMs: 100000, inAppSinceMs: 0, lastEventMs: 0, staleAfterMs: stale), isFalse);
    expect(counterPaused(nowMs: 179999, inAppSinceMs: 1, lastEventMs: 0, staleAfterMs: stale), isFalse);
    expect(counterPaused(nowMs: 200000, inAppSinceMs: 1, lastEventMs: 0, staleAfterMs: stale), isTrue);
    expect(counterPaused(nowMs: 200000, inAppSinceMs: 1, lastEventMs: 199000, staleAfterMs: stale), isFalse);
  });

  group('creator mode', () {
    test('off: everything counts', () {
      expect(countsAsFeed(rules, pkg: 'com.instagram.android', windowClass: 'DirectThreadActivity', sourceId: '', creatorMode: false), isTrue);
    });
    test('on: DMs, camera and editors don\'t count', () {
      bool counts(String pkg, String cls, String id) => countsAsFeed(rules, pkg: pkg, windowClass: cls, sourceId: id, creatorMode: true);
      expect(counts('com.instagram.android', 'com.instagram.direct.DirectThreadActivity', ''), isFalse);
      expect(counts('com.instagram.android', 'MainActivity', 'com.instagram.android:id/clips_viewer_view_pager'), isTrue);
      expect(counts('com.instagram.android', 'MainActivity', 'com.instagram.android:id/comment_list'), isFalse);
      expect(counts('com.google.android.youtube', 'WatchWhileActivity', 'com.google.android.youtube:id/reel_recycler'), isTrue);
      expect(counts('com.snapchat.android', 'CameraActivity', ''), isFalse);
      expect(counts('com.snapchat.android', 'LandingPageActivity', 'spotlight_pager'), isTrue);
    });
    test('hints come from config', () {
      final r = RealCountRules.from({'creator': {'apps': {'in.mohalla.video': {'feed_view_ids': ['in.mohalla.video:id/feed']}}}});
      expect(countsAsFeed(r, pkg: 'in.mohalla.video', windowClass: 'X', sourceId: 'in.mohalla.video:id/feed', creatorMode: true), isTrue);
      expect(countsAsFeed(r, pkg: 'in.mohalla.video', windowClass: 'X', sourceId: 'in.mohalla.video:id/other', creatorMode: true), isFalse);
    });
  });

  test('intention prompt: options from config, asked at most every 30 min', () {
    final o = intentionOptions(rules);
    expect(o.map((e) => e.id), ['dms', 'post', 'browse']);
    expect(o.last.minutes, 10);
    expect(tr('intent.browse', {'minutes': '10'}), 'Just browsing · 10 min');
    expect(shouldAskIntention(rules, nowMs: 31 * 60000, lastAskedMs: 0, enabled: true), isTrue);
    expect(shouldAskIntention(rules, nowMs: 29 * 60000, lastAskedMs: 0, enabled: true), isFalse);
    expect(shouldAskIntention(rules, nowMs: 31 * 60000, lastAskedMs: 0, enabled: false), isFalse);
    expect(shouldAskIntention(rules, nowMs: 31 * 60000, lastAskedMs: 0, enabled: true, focusOn: true), isFalse);
  });
}
