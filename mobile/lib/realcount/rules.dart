/// Real Count rules: every threshold the chip, the counter and the nudge engine use.
///
/// Source of truth is the shared config at `android.realcount` (core/rules, read through
/// `SnapyCore.config`), optionally overridden by a signed rules file fetched weekly
/// (see signed_rules.dart). The values in [RealCountRules.defaults] are only a safety net
/// for when config is missing — keep them identical to core/rules and to the Kotlin
/// mirror (RealCountRules in CounterLogic.kt).
library;

class RealCountRules {
  final Map<String, dynamic> raw;
  const RealCountRules._(this.raw);

  /// Safety-net defaults (mirrored in Kotlin `RealCountRules.DEFAULTS`).
  static const Map<String, dynamic> defaults = {
    'chip': {
      'sizes': {'small': 0.85, 'normal': 1.0, 'large': 1.25},
      'simple_mode_size': 'large',
      'height_dp': 26,
      'camera_gap_dp': 8,
      'wide_cutout_fraction': 0.25,    // a notch wider than this: sit below it, not on it
      'amber_at': 1.0,                 // fraction of the soft limit where the count turns amber
      'card_ms': 6000,
    },
    'nudges': {
      'min_gap_min': 20,               // at most one nudge every 20 minutes
      'session_reels': 30,             // reels in one session -> pulse + reset card
      'session_gap_min': 10,           // a session ends after 10 min without a reel
      'opens_per_hour': 10,            // same social app opened this often in an hour
      'soften_after_dismissals': 2,    // softer wording after two dismissals today
      'bedtime': '23:00',
      'wake': '06:00',
      'focus_min': 25,
      'reset_s': 120,
      'break_s': 10,
      'pause_counting_min': 60,
      'navigation_apps': [
        'com.google.android.apps.maps',
        'com.google.android.apps.mapslite',
        'com.waze',
        'com.mappls.app',
        'com.olacabs.customer',
        'com.ubercab',
        'com.ubercab.driver',
        'in.swiggy.deliveryapp',
        'com.application.zomato.ordering',
      ],
    },
    'intention': {
      'enabled': true,
      'ask_cooldown_min': 30,          // don't ask again on re-opening within 30 min
      'options': [
        {'id': 'dms', 'minutes': 5},
        {'id': 'post', 'minutes': 10},
        {'id': 'browse', 'minutes': 10},
      ],
    },
    'health': {
      'stale_after_s': 180,            // in a short-video app this long with no scroll events -> "counter paused"
    },
    'creator': {
      // screens that are creating/messaging, not consuming (window class or view id contains one)
      'keywords': ['camera', 'capture', 'creation', 'editor', 'composer', 'direct', 'thread', 'inbox', 'upload', 'share'],
      // per-app hints; feed_view_ids (when listed) are the only scroll sources that count.
      // These need checking on current app versions (they change with app updates).
      'apps': {
        'com.instagram.android': {
          'feed_view_ids': ['com.instagram.android:id/clips_viewer_view_pager'],
          'keywords': ['direct', 'camera', 'creation', 'clips_editor'],
        },
        'com.google.android.youtube': {
          'feed_view_ids': ['com.google.android.youtube:id/reel_recycler'],
          'keywords': ['upload', 'camera', 'editor'],
        },
      },
    },
    'habits': {
      'report_weekday': 7,             // ISO weekday: 7 = Sunday
      'three_ask_until': '12:00',
      'three_recap_after': '20:00',
      'streak_min_done': 1,            // of the daily three, for the day to count
      'streak_forgive_per_week': 1,
    },
    'rules_update': {
      'url': '',                       // empty = updates off (no endpoint yet)
      'public_key': '',                // Ed25519, base64 (32 bytes)
      'interval_days': 7,
    },
  };

  factory RealCountRules.from(dynamic config, {dynamic override}) {
    final merged = deepMerge(defaults, config is Map ? config : const {});
    return RealCountRules._(override is Map ? deepMerge(merged, override) : merged);
  }

  static const RealCountRules fallback = RealCountRules._(defaults);

  dynamic get(String dotted) {
    dynamic v = raw;
    for (final k in dotted.split('.')) {
      if (v is! Map) return null;
      v = v[k];
    }
    return v;
  }

  int i(String dotted) => (get(dotted) as num?)?.toInt() ?? (_def(dotted) as num).toInt();
  double d(String dotted) => (get(dotted) as num?)?.toDouble() ?? (_def(dotted) as num).toDouble();
  String s(String dotted) => (get(dotted) ?? _def(dotted) ?? '').toString();
  bool b(String dotted) => (get(dotted) ?? _def(dotted)) == true;
  List<String> list(String dotted) => ((get(dotted) ?? _def(dotted) ?? const []) as List).map((e) => e.toString()).toList();

  dynamic _def(String dotted) => fallback.get(dotted);

  /// "23:00" -> minutes after midnight.
  int minutesOfDay(String dotted) => parseHm(s(dotted));
}

int parseHm(String hm) {
  final p = hm.split(':');
  final h = int.tryParse(p.first) ?? 0;
  final m = p.length > 1 ? int.tryParse(p[1]) ?? 0 : 0;
  return (h.clamp(0, 23)) * 60 + m.clamp(0, 59);
}

Map<String, dynamic> deepMerge(Map base, Map over) {
  final out = <String, dynamic>{for (final e in base.entries) e.key.toString(): e.value};
  for (final e in over.entries) {
    final k = e.key.toString();
    final a = out[k], b = e.value;
    out[k] = (a is Map && b is Map) ? deepMerge(a, b) : b;
  }
  return out;
}
