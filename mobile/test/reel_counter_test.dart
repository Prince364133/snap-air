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

  ReelScroll reel(int t, {String key = '', int from = -1, int to = -1, int count = -1, double h = 1.0, String id = pager, String pkg = ig, bool short = true, int dy = 0}) =>
      ReelScroll(pkg: pkg, shortVideoApp: short, heightFraction: h, widthFraction: 1, sourceId: id, fromIndex: from, toIndex: to, itemCount: count,
          scrollDeltaY: dy, screenHeight: 2400, itemKey: key, nowMs: t);

  test('ViewPager2 with -1 indices: counted once per new item (by the visible item identity)', () {
    final c = ReelCounter(rules);
    final got = [
      c.onScroll(reel(0, key: 'A')), // first item: baseline
      c.onScroll(reel(200, key: 'A')), // same item, more scroll events
      c.onScroll(reel(1500, key: 'B')), // A watched 1.5 s -> counted
      c.onScroll(reel(1600, key: 'B')),
      c.onScroll(reel(4000, key: 'C')), // B watched -> counted
    ];
    expect(got.where((d) => d == ReelDecision.counted).length, 2);
    expect(got[1], ReelDecision.sameItem);
  });

  test('flicks under the dwell are not counted', () {
    final c = ReelCounter(rules);
    c.onScroll(reel(0, key: 'A'));
    expect(c.onScroll(reel(300, key: 'B')), ReelDecision.flick);
    expect(c.onScroll(reel(500, key: 'C')), ReelDecision.flick);
    expect(c.onScroll(reel(2000, key: 'D')), ReelDecision.counted);
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

  test('no index, no identity: a page-sized scroll (API 28+)', () {
    final c = ReelCounter(const ReelCounterRules());
    expect(c.onScroll(reel(0, id: '', pkg: 'app.short', dy: 40)), ReelDecision.sameItem);
    expect(c.onScroll(reel(1200, id: '', pkg: 'app.short', dy: 1300)), ReelDecision.counted);
  });

  test('leaving the feed resets the run', () {
    final c = ReelCounter(rules);
    c.onScroll(reel(0, key: 'A'));
    c.reset(ig);
    expect(c.onScroll(reel(5000, key: 'B')), ReelDecision.sameItem, reason: 'a fresh baseline, not a count');
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
