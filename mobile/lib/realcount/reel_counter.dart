// The reel counter's decision: does this scroll event mean one more short video watched?
//
// MIRROR: android/app/src/main/kotlin/live/snapy/app/ReelCounter.kt (ReelCounter) — the ONE
// counting path on Android (RealCountController calls it; SnapyAccessibilityService only
// forwards events). test/reel_counter_test.dart pins the behaviour.
//
// An event counts only when ALL hold:
//  1. the app is a short-video app of the catalogue (core rules android.social_apps with a
//     non-null `short_video`) — no package-name guessing;
//  2. the scrolled view is the full-screen pager: height >= feed_min_height_fraction of the
//     screen (and nearly full width), and, when the app lists feed view IDs
//     (android.realcount.creator.apps.<pkg>.feed_view_ids), the source is one of them;
//     a pager shows at most two items at once (a home feed / comment list shows more);
//  3. creator screens (camera, DMs, editor…; ChipLogic.countsAsFeed keywords) don't count;
//  4. the page changed: item indices when the app reports them, else (ViewPager2 often sends
//     -1 indices and scrollDeltaY 0) the identity of the visible item (a hash of its
//     caption/author/description), else a scroll of >= page_scroll_fraction of the screen;
//  5. the item that was showing stayed at least min_reel_dwell_ms (a flick past isn't a watch).
// The watched item is counted when the user moves on from it, so each item counts once.

class ReelScroll {
  final String pkg;
  final bool shortVideoApp; // in the catalogue with short_video
  final double heightFraction; // source height / screen height (0 = unknown)
  final double widthFraction; // source width / screen width (0 = unknown)
  final String sourceId; // view id resource name ('' = unknown)
  final String windowClass;
  final int fromIndex, toIndex, itemCount;
  final int scrollDeltaY; // API 28+, 0 = unknown
  final int screenHeight;
  final String itemKey; // identity of the visible item ('' = unknown)
  final int nowMs;

  const ReelScroll({
    required this.pkg,
    required this.shortVideoApp,
    this.heightFraction = 0,
    this.widthFraction = 0,
    this.sourceId = '',
    this.windowClass = '',
    this.fromIndex = -1,
    this.toIndex = -1,
    this.itemCount = -1,
    this.scrollDeltaY = 0,
    this.screenHeight = 0,
    this.itemKey = '',
    required this.nowMs,
  });
}

class ReelCounterRules {
  final int minDwellMs;
  final double minHeightFraction;
  final double minWidthFraction;
  final double pageScrollFraction;
  final Map<String, List<String>> feedViewIds; // pkg -> pager view ids
  final List<String> creatorKeywords; // global + per app merged by the caller
  final Map<String, List<String>> appKeywords;

  const ReelCounterRules({
    this.minDwellMs = 700,
    this.minHeightFraction = 0.6,
    this.minWidthFraction = 0.9,
    this.pageScrollFraction = 0.5,
    this.feedViewIds = const {},
    this.creatorKeywords = const [],
    this.appKeywords = const {},
  });

  /// From the merged config tree's `android` block (min_reel_dwell_ms, realcount.*).
  factory ReelCounterRules.fromAndroidConfig(Map<String, dynamic>? android) {
    final a = android ?? const {};
    final rc = (a['realcount'] as Map?) ?? const {};
    final det = (rc['reel_detection'] as Map?) ?? const {};
    final creator = (rc['creator'] as Map?) ?? const {};
    final apps = (creator['apps'] as Map?) ?? const {};
    List<String> strs(Object? v) => v is List ? [for (final e in v) '$e'] : const [];
    return ReelCounterRules(
      minDwellMs: (a['min_reel_dwell_ms'] as num?)?.toInt() ?? 700,
      minHeightFraction: (det['feed_min_height_fraction'] as num?)?.toDouble() ?? 0.6,
      minWidthFraction: (det['feed_min_width_fraction'] as num?)?.toDouble() ?? 0.9,
      pageScrollFraction: (det['page_scroll_fraction'] as num?)?.toDouble() ?? 0.5,
      feedViewIds: {for (final e in apps.entries) '${e.key}': strs((e.value as Map?)?['feed_view_ids'])},
      creatorKeywords: strs(creator['keywords']),
      appKeywords: {for (final e in apps.entries) '${e.key}': strs((e.value as Map?)?['keywords'])},
    );
  }
}

class _Feed {
  int lastIndex = -1;
  String lastKey = '';
  int shownAt = 0; // when the current item appeared
}

enum ReelDecision { notFeed, sameItem, flick, counted }

class ReelCounter {
  final ReelCounterRules rules;
  final Map<String, _Feed> _feeds = {};
  ReelCounter([this.rules = const ReelCounterRules()]);

  /// Left the feed (another app or screen): the next item starts a fresh run.
  void reset([String? pkg]) => pkg == null ? _feeds.clear() : _feeds.remove(pkg);

  bool isFeed(ReelScroll e) {
    if (!e.shortVideoApp) return false;
    if (e.heightFraction > 0 && e.heightFraction < rules.minHeightFraction) return false;
    if (e.widthFraction > 0 && e.widthFraction < rules.minWidthFraction) return false;
    final ids = rules.feedViewIds[e.pkg] ?? const [];
    if (ids.isNotEmpty && e.sourceId.isNotEmpty && !ids.contains(e.sourceId)) return false;
    if (e.fromIndex >= 0 && e.toIndex >= 0 && e.toIndex - e.fromIndex > 1) return false; // 3+ items visible: a list
    final hay = '${e.windowClass.toLowerCase()} ${e.sourceId.toLowerCase()}';
    for (final w in [...rules.creatorKeywords, ...?rules.appKeywords[e.pkg]]) {
      if (w.isNotEmpty && hay.contains(w.toLowerCase())) return false;
    }
    return true;
  }

  ReelDecision onScroll(ReelScroll e) {
    if (!isFeed(e)) return ReelDecision.notFeed;
    final f = _feeds.putIfAbsent(e.pkg, () => _Feed()..shownAt = e.nowMs);
    bool changed;
    if (e.fromIndex >= 0 && e.itemCount > 1) {
      changed = f.lastIndex >= 0 && f.lastIndex != e.fromIndex;
      final first = f.lastIndex < 0;
      f.lastIndex = e.fromIndex;
      if (e.itemKey.isNotEmpty) f.lastKey = e.itemKey;
      if (first) {
        f.shownAt = e.nowMs;
        return ReelDecision.sameItem;
      }
    } else if (e.itemKey.isNotEmpty) {
      changed = f.lastKey.isNotEmpty && f.lastKey != e.itemKey;
      final first = f.lastKey.isEmpty;
      f.lastKey = e.itemKey;
      if (first) {
        f.shownAt = e.nowMs;
        return ReelDecision.sameItem;
      }
    } else {
      changed = e.screenHeight > 0 && e.scrollDeltaY.abs() >= e.screenHeight * rules.pageScrollFraction;
    }
    if (!changed) return ReelDecision.sameItem;
    final dwelled = e.nowMs - f.shownAt;
    f.shownAt = e.nowMs;
    return dwelled >= rules.minDwellMs ? ReelDecision.counted : ReelDecision.flick;
  }
}
