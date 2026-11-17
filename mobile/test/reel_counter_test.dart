// The reel counter's decision (lib/realcount/reel_counter.dart, mirrored in ReelCounter.kt).
import 'package:flutter_test/flutter_test.dart';
import 'package:snapy/realcount/reel_counter.dart';

void main() {
  const ig = 'com.instagram.android';
  const pager = 'com.instagram.android:id/clips_viewer_view_pager';
  final rules = ReelCounterRules(
    minDwellMs: 700,
    feedViewIds: {ig: [pager]},
    creatorKeywords: const ['camera', 'direct', 'composer'],
  );

  ReelScroll reel(int t, {String key = '', int from = -1, int to = -1, int count = -1, double h = 1.0, String id = pager, String pkg = ig, bool short = true, int dy = 0, int dx = 0}) =>
      ReelScroll(pkg: pkg, shortVideoApp: short, heightFraction: h, widthFraction: 1, sourceId: id, fromIndex: from, toIndex: to, itemCount: count,
          scrollDeltaY: dy, scrollDeltaX: dx, screenHeight: 2400, itemKey: key, nowMs: t);

  test('Instagram ViewPager2 (-1 indices, deltaY 0, same labels on every reel): one count per swipe', () {
    final c = ReelCounter(rules);
    final got = [
      // swipe 1: a burst of events -> the reel that was showing counts once
      c.onScroll(reel(0, key: 'Like Comment Share')),
      c.onScroll(reel(100, key: 'Like Comment Share')),
      c.onScroll(reel(200, key: 'Like Comment Share')),
      // watching, then swipe 2
      c.onScroll(reel(5000, key: 'Like Comment Share')),
      c.onScroll(reel(5150, key: 'Like Comment Share')),
      // swipe 3, no labels readable at all
      c.onScroll(reel(9000)),
      c.onScroll(reel(9100)),
    ];
    expect(got.where((d) => d == ReelDecision.counted).length, 3);
    expect(got[1], ReelDecision.sameItem);
    expect(got[2], ReelDecision.sameItem);
  });

  test('one long fling through several items is one burst: counted once', () {
    final c = ReelCounter(rules);
    var n = 0;
    for (var t = 0; t <= 1000; t += 100) {
      if (c.onScroll(reel(t, key: 'k$t')) == ReelDecision.counted) n++;
    }
    expect(n, 1);
  });

  test('flicks under the dwell are not counted', () {
    final c = ReelCounter(rules);
    expect(c.onScroll(reel(0)), ReelDecision.counted); // the reel showing on opening
    expect(c.onScroll(reel(600)), ReelDecision.flick); // next swipe after 0.6 s
    expect(c.onScroll(reel(1200)), ReelDecision.flick);
    expect(c.onScroll(reel(3000)), ReelDecision.counted);
  });

  test('sideways swipes (camera / DMs) and sources of unknown size are not counted', () {
    final c = ReelCounter(rules);
    expect(c.onScroll(reel(0, dx: 900, dy: 0)), ReelDecision.notFeed);
    expect(c.onScroll(reel(2000, h: 0)), ReelDecision.sameItem, reason: 'a ticker / view without bounds');
  });

  test('item indices when the app reports them', () {
    final c = ReelCounter(rules);
    expect(c.onScroll(reel(0, from: 3, to: 3, count: 50)), ReelDecision.sameItem);
    expect(c.onScroll(reel(100, from: 3, to: 4, count: 50)), ReelDecision.sameItem);
    expect(c.onScroll(reel(1000, from: 4, to: 4, count: 50)), ReelDecision.counted);
  });

  test('home-feed scrolling is not counted (not the reels pager id)', () {
    final c = ReelCounter(rules);
    for (var t = 0; t < 10000; t += 900) {
      expect(c.onScroll(reel(t, key: 'post$t', id: 'com.instagram.android:id/list')), ReelDecision.notFeed);
    }
  });

  test('home feed without known ids: a list showing 3+ items is not a pager', () {
    final c = ReelCounter(const ReelCounterRules());
    expect(c.onScroll(reel(0, from: 0, to: 3, count: 40, id: '', pkg: 'app.short')), ReelDecision.notFeed);
  });

  test('comments sheet is not counted (not full height)', () {
    final c = ReelCounter(rules);
    expect(c.onScroll(reel(0, key: 'c1', h: 0.55, id: '')), ReelDecision.notFeed);
    expect(c.onScroll(reel(1000, key: 'c2', h: 0.55, id: '')), ReelDecision.notFeed);
  });

  test('DMs / camera screens are not counted', () {
    final c = ReelCounter(rules);
    expect(c.onScroll(reel(0, key: 'x', id: 'com.instagram.android:id/direct_thread_list')), ReelDecision.notFeed);
  });

  test('apps outside the catalogue (Messenger, Threads…) are never counted', () {
    final c = ReelCounter(rules);
    expect(c.onScroll(reel(0, key: 'A', pkg: 'com.facebook.orca', short: false, id: '')), ReelDecision.notFeed);
    expect(c.onScroll(reel(2000, key: 'B', pkg: 'com.facebook.orca', short: false, id: '')), ReelDecision.notFeed);
  });

  test('no index: one count per burst, even with a page-sized move inside it', () {
    final c = ReelCounter(const ReelCounterRules());
    expect(c.onScroll(reel(0, id: '', pkg: 'app.short', dy: 40)), ReelDecision.counted);
    expect(c.onScroll(reel(200, id: '', pkg: 'app.short', dy: 1300)), ReelDecision.sameItem, reason: 'same swipe');
    expect(c.onScroll(reel(1500, id: '', pkg: 'app.short', dy: 1300)), ReelDecision.counted);
  });

  test('leaving the feed resets the run', () {
    final c = ReelCounter(rules);
    c.onScroll(reel(0, key: 'A'));
    c.reset(ig);
    expect(c.onScroll(reel(5000, key: 'B')), ReelDecision.counted, reason: 'a fresh run: the reel showing on return counts at the first swipe');
    expect(c.onScroll(reel(5100, key: 'B')), ReelDecision.sameItem);
  });

  test('rules from the merged android config', () {
    final r = ReelCounterRules.fromAndroidConfig({
      'min_reel_dwell_ms': 900,
      'realcount': {
        'reel_detection': {'feed_min_height_fraction': 0.7, 'page_scroll_fraction': 0.4},
        'creator': {
          'keywords': ['camera'],
          'apps': {
            ig: {'feed_view_ids': [pager], 'keywords': ['clips_editor']}
          }
        },
      },
    });
    expect(r.minDwellMs, 900);
    expect(r.minHeightFraction, 0.7);
    expect(r.feedViewIds[ig], [pager]);
    expect(r.appKeywords[ig], ['clips_editor']);
  });
}
