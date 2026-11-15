/// Pure logic behind the Real Count chip and counter (mirrored in Kotlin CounterLogic.kt):
/// text and tone, the limit ring, where the chip sits on the camera cut-out, when it hides
/// itself, the "counter paused" health check, creator mode and the intention prompt.
library;

import 'dart:math' as math;

import 'rules.dart';

// ------------------------------------------------------------------ text, tone, ring
enum ChipTone { normal, amber, dim, paused }

String formatDuration(int ms) {
  final m = ms ~/ 60000;
  return m >= 60 ? '${m ~/ 60}h ${m % 60}m' : '${m}m';
}

/// How far toward the soft limit (0 = no limit set). The higher of time and reels.
double limitFraction({int usedMs = 0, int limitMin = 0, int reels = 0, int reelLimit = 0}) {
  var f = 0.0;
  if (limitMin > 0) f = math.max(f, usedMs / (limitMin * 60000));
  if (reelLimit > 0) f = math.max(f, reels / reelLimit);
  return f;
}

ChipTone chipTone({required double fraction, required double amberAt, bool bedtime = false, bool paused = false}) {
  if (paused) return ChipTone.paused;
  if (fraction > 0 && fraction >= amberAt) return ChipTone.amber;   // amber, never red
  if (bedtime) return ChipTone.dim;
  return ChipTone.normal;
}

/// The ring around the orb fills toward the limit and stays full after it.
double ringProgress(double fraction) => fraction.isNaN ? 0 : fraction.clamp(0.0, 1.0);

// ------------------------------------------------------------------ placement
class Rect4 {
  final int left, top, right, bottom;
  const Rect4(this.left, this.top, this.right, this.bottom);
  int get width => right - left;
  int get height => bottom - top;
  int get centerX => (left + right) ~/ 2;
  int get centerY => (top + bottom) ~/ 2;
}

class ChipPlacement {
  final int x, y;
  final int cameraGap;    // px of empty space in the middle of the chip for the camera hole (0 = none)
  final int height;       // the chip grows to cover a tall camera hole
  const ChipPlacement(this.x, this.y, this.cameraGap, this.height);
  @override
  String toString() => 'ChipPlacement($x, $y, gap $cameraGap, h $height)';
}

/// Centre the chip on the camera cut-out (the chip wraps around the hole, island style).
/// A wide notch: centred just below it. No cut-out: top-centre in the status bar row.
/// [saved] is where the user dragged it (wins when set).
ChipPlacement placeChip({
  required int screenW,
  required int statusBarH,
  required int chipW,           // width without the camera gap
  required int chipH,
  List<Rect4> cutouts = const [],
  int gapPadPx = 0,
  double wideFraction = 0.25,
  (int, int)? saved,
}) {
  int clampX(int x, int w) => x.clamp(0, math.max(0, screenW - w));
  if (saved != null) return ChipPlacement(clampX(saved.$1, chipW), math.max(0, saved.$2), 0, chipH);
  final top = cutouts.where((r) => r.top < math.max(statusBarH, chipH * 2)).toList()   // top-edge cut-outs only
    ..sort((a, b) => a.top.compareTo(b.top));
  if (top.isEmpty) {
    return ChipPlacement(clampX((screenW - chipW) ~/ 2, chipW), math.max(0, (statusBarH - chipH) ~/ 2), 0, chipH);
  }
  final c = top.first;
  if (c.width > screenW * wideFraction) {
    return ChipPlacement(clampX((screenW - chipW) ~/ 2, chipW), c.bottom + gapPadPx, 0, chipH);
  }
  final gap = c.width + 2 * gapPadPx;
  final w = chipW + gap;
  final h = math.max(chipH, c.height + gapPadPx);
  return ChipPlacement(clampX(c.centerX - w ~/ 2, w), math.max(0, c.centerY - h ~/ 2), gap, h);
}

// ------------------------------------------------------------------ auto-hide
class HideSignals {
  final bool fullscreen;      // the app hid the status bar (video, reader, game)
  final bool game;            // ApplicationInfo.CATEGORY_GAME
  final bool locked;          // keyguard showing / screen off
  final bool inCall;          // AudioManager mode in call / communication
  final bool userHidden;      // chip turned off
  final bool hiddenToday;     // "hide for today"
  final bool hiddenForNow;    // "hide for 1 hour"
  const HideSignals({this.fullscreen = false, this.game = false, this.locked = false, this.inCall = false,
      this.userHidden = false, this.hiddenToday = false, this.hiddenForNow = false});
}

/// Voice feedback ([listening]) still shows over a full-screen app, never on the lock screen.
bool chipHidden(HideSignals s, {bool listening = false}) {
  if (s.locked || s.userHidden) return true;
  if (listening) return false;
  return s.fullscreen || s.game || s.inCall || s.hiddenToday || s.hiddenForNow;
}

// ------------------------------------------------------------------ counter health
/// "counter paused" instead of a wrong number: in a short-video app for a while with no
/// scroll events at all from it means the accessibility events stopped (service killed,
/// app redesigned). Clears as soon as an event arrives.
bool counterPaused({required int nowMs, required int inAppSinceMs, required int lastEventMs, required int staleAfterMs}) {
  if (inAppSinceMs <= 0) return false;
  final since = math.max(inAppSinceMs, lastEventMs);
  return nowMs - since >= staleAfterMs;
}

// ------------------------------------------------------------------ creator mode
/// Creator mode: posting, editing and DMs aren't consuming — only feed scrolls count.
/// [windowClass] is the last window/activity class of the app, [sourceId] the scrolled view's id.
bool countsAsFeed(RealCountRules rules, {required String pkg, required String windowClass, required String sourceId,
    required bool creatorMode}) {
  if (!creatorMode) return true;
  final apps = rules.get('creator.apps');                 // packages contain dots: not a dotted path
  final app = apps is Map ? apps[pkg] : null;
  final feedIds = (app is Map ? (app['feed_view_ids'] as List?) : null)?.map((e) => e.toString()).toList() ?? const <String>[];
  if (feedIds.isNotEmpty && sourceId.isNotEmpty) return feedIds.contains(sourceId);
  final words = <String>{
    ...rules.list('creator.keywords'),
    ...((app is Map ? (app['keywords'] as List?) : null) ?? const []).map((e) => e.toString()),
  };
  final hay = '${windowClass.toLowerCase()} ${sourceId.toLowerCase()}';
  return !words.any((w) => w.isNotEmpty && hay.contains(w.toLowerCase()));
}

// ------------------------------------------------------------------ intention prompt
class IntentionOption {
  final String id;
  final int minutes;
  const IntentionOption(this.id, this.minutes);
}

List<IntentionOption> intentionOptions(RealCountRules rules) {
  final raw = rules.get('intention.options');
  if (raw is! List) return const [];
  return [
    for (final o in raw)
      if (o is Map && o['id'] != null) IntentionOption(o['id'].toString(), (o['minutes'] as num?)?.toInt() ?? 10),
  ];
}

/// Ask "What are you here for?" when a social app opens — unless asked recently,
/// a focus session is on (that has its own card), or there's already a plan running.
bool shouldAskIntention(RealCountRules rules, {required int nowMs, required int lastAskedMs, required bool enabled,
    bool focusOn = false, bool planRunning = false}) {
  if (!enabled || !rules.b('intention.enabled') || focusOn || planRunning) return false;
  return nowMs - lastAskedMs >= rules.i('intention.ask_cooldown_min') * 60000;
}
