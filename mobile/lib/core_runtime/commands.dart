// The phone subset of Snapy's command grammar (engine/src/ai/agent_controller.py): every side
// effect becomes an {"type":"op"} event that Kotlin's OpExecutor runs (open app/url, media keys,
// volume, back/home/recents via android.key_actions). Plus the installed-app finder
// (platform/android.py AndroidApps) and the on-screen matcher (os_control/screen.py find).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'core_data.dart';
import 'py.dart';
import 'rules.dart';

class CmdResult {
  final bool ok;
  final String message;
  final String? action;
  CmdResult(this.ok, this.message, [this.action]);
  @override
  String toString() => 'CmdResult($ok, $message, $action)';
}

/// Installed apps (label -> package), sent by Kotlin. Same find() contract as the desktop AppIndex.
class AndroidApps {
  final Map<String, String> apps = {};

  void set(List<dynamic> items) {
    apps.clear();
    for (final i in items) {
      final m = i as Map;
      final label = m['label'], pkg = m['package'];
      if (label != null && '$label'.isNotEmpty && pkg != null && '$pkg'.isNotEmpty) apps['$label'.toLowerCase()] = '$pkg';
    }
  }

  (String, String)? find(String? name) {
    final q = (name ?? '').toLowerCase().trim();
    if (q.isEmpty || apps.isEmpty) return null;
    if (apps.containsKey(q)) return (q, apps[q]!);
    final starts = apps.keys.where((k) => k.startsWith(q) || k.split(RegExp(r'\s+')).contains(q)).toList();
    if (starts.isNotEmpty) {
      var best = starts.first;
      for (final k in starts) {
        if (k.length < best.length) best = k;
      }
      return (best, apps[best]!);
    }
    final close = closeMatch(q, apps.keys, cutoff: 0.75);
    return close != null ? (close, apps[close]!) : null;
  }
}

typedef OpEmit = void Function(String op, {List<Object?> args, Map<String, Object?> kwargs});

class PhoneCommands {
  final CoreData core;
  final Rules rules;
  final AndroidApps apps;
  final OpEmit op;
  final void Function(Map<String, dynamic> event) ui;
  final String Function() agentName;
  final List<String> Function() wakeWords;
  final Future<String?> Function(Uri url)? fetch; // YouTube result lookup (null in tests)

  PhoneCommands(this.core, this.rules, this.apps, this.op, this.ui, this.agentName, this.wakeWords, {this.fetch});

  static const websites = {
    'youtube': 'https://www.youtube.com', 'gmail': 'https://mail.google.com', 'google': 'https://www.google.com',
    'github': 'https://github.com', 'chatgpt': 'https://chat.openai.com', 'claude': 'https://claude.ai',
    'netflix': 'https://www.netflix.com', 'twitter': 'https://x.com', 'x': 'https://x.com',
    'linkedin': 'https://www.linkedin.com', 'reddit': 'https://www.reddit.com', 'whatsapp': 'https://web.whatsapp.com',
    'google drive': 'https://drive.google.com', 'drive': 'https://drive.google.com', 'google docs': 'https://docs.google.com',
    'maps': 'https://maps.google.com', 'google maps': 'https://maps.google.com', 'calendar': 'https://calendar.google.com',
    'stack overflow': 'https://stackoverflow.com', 'amazon': 'https://www.amazon.com', 'instagram': 'https://www.instagram.com',
    'facebook': 'https://www.facebook.com', 'wikipedia': 'https://www.wikipedia.org',
  };

  // ------------------------------------------------------------ ops
  void openUrl(String url) {
    final host = (Uri.tryParse(url)?.host ?? '').toLowerCase();
    final links = (core.config('android.app_links') as Map?) ?? const {};
    final parts = host.split('.');
    final pkg = links[host] ?? links[host.startsWith('www.') ? host.substring(4) : host] ??
        links[parts.length >= 2 ? parts.sublist(parts.length - 2).join('.') : host];
    op('open_url', args: [url], kwargs: {'package': ?pkg});
  }

  void _hotkey(List<String> keys) => op('hotkey', args: keys);
  void _media(String key, [int times = 1]) => op('media', args: times == 1 ? [key] : [key, times]);

  // ------------------------------------------------------------ pipeline
  bool _isHallucination(String cmd) => List<String>.from((core.config('vocab.hallucinations') as List?) ?? const []).contains(cmd);

  /// AgentController.execute_intent for the phone. null-safe: unknown -> action "unknown".
  Future<CmdResult> execute(String text, {bool requireWake = false}) async {
    final raw = text.trim();
    var (heard, cmd) = rules.stripWake(raw, agentName: agentName(), wakeWords: wakeWords());
    if (requireWake && !heard) return CmdResult(false, '', 'ignored');
    if (_isHallucination(cmd) && !heard) return CmdResult(false, '', 'ignored');
    if (heard && cmd.isEmpty) return CmdResult(true, 'Listening for a command…', 'wake');
    var original = rules.stripWakeOriginal(raw, agentName: agentName(), wakeWords: wakeWords());
    cmd = rules.plain(cmd);
    original = rules.plainOriginal(original);
    final special = _special(cmd);
    if (special != null) return special;
    final (cmdWo, nth) = rules.ordinal(cmd);
    final play = rules.playRequest(cmdWo);
    if (play != null) {
      await playYoutube(play, nth ?? 1);
      final which = nth != null && nth > 1 ? ' (result $nth)' : '';
      return CmdResult(true, 'Playing "$play" on YouTube$which', 'youtube');
    }
    var result = await _run(cmd, original) ?? await _tryCompound(cmd, original);
    return result ?? CmdResult(false, 'Didn\'t understand "$cmd". Say "${agentName()}, help" for commands.', 'unknown');
  }

  static final _quit = RegExp(r'^(?:close|quit|exit|shut ?down|turn off|stop|band karo|band ho ja(?:o)?|band kar do)'
      r'(?: (?:yourself|snapy|snappy|snap|the assistant|the app|assistant))?(?: now| please)?$');
  static final _emoji = RegExp(r'^(?:.*\b)?(?:emoji|emojis|emoticons|smileys)\b.*$');

  CmdResult? _special(String cmd) {
    final name = Rules.normalizeText(agentName());
    final first = cmd.split(' ').first;
    if (_quit.hasMatch(cmd) &&
        (const ['quit', 'exit', 'shutdown', 'shut', 'band'].contains(first) ||
            RegExp('yourself|snapy|snappy|snap\\b|assistant|the app|${RegExp.escape(name)}').hasMatch(cmd))) {
      ui({'type': 'ui_action', 'action': 'quit'});
      return CmdResult(true, 'Closing ${agentName()}. See you soon!', 'quit');
    }
    if (_emoji.hasMatch(cmd) &&
        RegExp(r'\b(show|render|display|put|throw|send|rain|shower|draw|dikhao|bhejo|karo|some|good|nice|cool)\b').hasMatch(cmd)) {
      final sets = Map<String, dynamic>.from((core.config('emoji_sets') as Map?) ?? const {});
      List chosen = (sets['default'] as List?) ?? const [];
      for (final e in sets.entries) {
        if (e.key != 'default' && RegExp('\\b(?:${e.key})').hasMatch(cmd)) {
          chosen = e.value as List;
          break;
        }
      }
      ui({'type': 'ui_action', 'action': 'emoji', 'emojis': chosen});
      return CmdResult(true, 'Here you go! ${chosen.take(4).join(' ')}', 'emoji');
    }
    return null;
  }

  Future<CmdResult?> _tryCompound(String cmd, String original) async {
    for (final sep in [' and then ', ' then ', ' and ']) {
      if (!cmd.contains(sep)) continue;
      final parts = cmd.split(sep);
      final oparts = original.split(RegExp(RegExp.escape(sep.trim()), caseSensitive: false));
      final results = <CmdResult>[];
      var all = true;
      for (var i = 0; i < parts.length; i++) {
        final op = oparts.length == parts.length ? oparts[i] : parts[i];
        final r = await _run(parts[i].trim(), op.trim());
        if (r == null) {
          all = false;
          break;
        }
        results.add(r);
      }
      if (all) return CmdResult(results.every((r) => r.ok), results.map((r) => r.message).join(' → '), 'compound');
    }
    return null;
  }

  int _parseCount(String s, num def) {
    s = s.trim();
    if (s.isEmpty) return def.round();
    final m = RegExp(r'\d+').firstMatch(s);
    if (m != null) return int.parse(m[0]!).clamp(1, 50);
    for (final e in ((core.config('vocab.numbers.count') as Map?) ?? const {}).entries) {
      if (RegExp('\\b${e.key}\\b').hasMatch(s)) return (e.value as num).toInt();
    }
    return def.round();
  }

  /// The grammar: (fullmatch pattern, handler). A handler may return null (try the next rule).
  late final List<(RegExp, FutureOr<CmdResult?> Function(RegExpMatch m, String orig))> _commands = [
    (_fm(r'(?:go )?back|previous page'), (m, o) {
      _hotkey(['alt', 'left']);
      return CmdResult(true, 'Back', 'nav');
    }),
    (_fm(r'(?:go )?(?:to )?(?:the )?home(?: screen)?|(?:minimi[sz]e all|show (?:the )?desktop|hide (?:all )?windows|clear (?:the )?screen)'), (m, o) {
      _hotkey(['win', 'd']);
      return CmdResult(true, 'Home', 'window');
    }),
    (_fm(r'(?:task view|show (?:all )?windows|all windows|recent apps|recents|show recents)'), (m, o) {
      _hotkey(['win', 'tab']);
      return CmdResult(true, 'Recent apps', 'window');
    }),
    (_fm(r'(?:open |show )?(?:the )?notifications(?: panel)?'), (m, o) {
      _hotkey(['win', 'n']);
      return CmdResult(true, 'Notifications', 'window');
    }),
    (_fm(r'(?:open |show )?(?:the )?quick settings'), (m, o) {
      _hotkey(['win', 'a']);
      return CmdResult(true, 'Quick settings', 'window');
    }),
    (_fm(r'(?:take a )?(?:screenshot|screen shot|capture (?:the )?screen|snip)'), (m, o) {
      op('press', args: ['printscreen']);
      return CmdResult(true, 'Screenshot', 'window');
    }),
    (_fm(r'lock (?:the |my )?(?:screen|phone|computer|pc|laptop|system)|lock it'), (m, o) {
      _hotkey(['win', 'l']);
      return CmdResult(true, 'Locked', 'window');
    }),
    (_fm(r'(?:play|pause|resume|play pause|pause (?:the )?(?:video|music|song)|play (?:the )?(?:video|music)|toggle play)'), (m, o) {
      _media('playpause');
      return CmdResult(true, 'Play/Pause', 'media');
    }),
    (_fm(r'(?:next|skip)(?: (?:song|track|video))?|skip (?:this|it)'), (m, o) {
      _media('nexttrack');
      return CmdResult(true, 'Next track', 'media');
    }),
    (_fm(r'(?:previous|last|prev) (?:song|track|video)'), (m, o) {
      _media('prevtrack');
      return CmdResult(true, 'Previous track', 'media');
    }),
    (_fm(r'(?:turn (?:the )?)?(?:volume (up|down)|(?:turn it|turn) (up|down)|(louder)|(quieter|softer))(?: (?:by )?(.+?))?'), (m, o) {
      final up = m[1] == 'up' || m[2] == 'up' || m[3] != null;
      final amount = m[5] ?? '';
      int presses;
      if (amount.isEmpty) {
        presses = 5;
      } else if (RegExp(r'\blot\b|much|way').hasMatch(amount)) {
        presses = 10;
      } else {
        final n = _parseCount(amount, 10);
        presses = n < 1 ? 2 : (pyRound(n / 2) < 1 ? 1 : pyRound(n / 2));
      }
      _media(up ? 'volumeup' : 'volumedown', presses);
      return CmdResult(true, 'Volume ${up ? 'up' : 'down'} (${presses * 2}%)', 'media');
    }),
    (_fm(r'(?:mute|unmute|toggle mute|silence)(?: (?:the )?(?:sound|audio|volume))?'), (m, o) {
      _media('volumemute');
      return CmdResult(true, 'Toggled mute', 'media');
    }),
    (_fm(r'(?:play|watch|put on) (.+?) on youtube|youtube (?:play |search )?(.+)|search youtube for (.+)|(?:open youtube and )?(?:play|watch) (.+?)(?: on youtube)?'),
        (m, o) async {
      if (!m[0]!.contains('youtube')) return null;
      final q = [m[1], m[2], m[3], m[4]].firstWhere((g) => g != null && g.isNotEmpty, orElse: () => '')!;
      await playYoutube(q);
      return CmdResult(true, 'Playing "$q" on YouTube', 'youtube');
    }),
    (_fm(r'(?:play|put on) (.+?) on spotify'), (m, o) {
      openUrl('spotify:search:${Uri.encodeComponent(m[1]!)}');
      return CmdResult(true, 'Searching Spotify for "${m[1]}" — press play', 'spotify');
    }),
    (_fm(r'(?:play|put on|watch) (?:some )?(.+)'), (m, o) async {
      final q = m[1]!;
      if (const ['it', 'that', 'this', 'music', 'video', 'the video', 'the music'].contains(q)) return null;
      await playYoutube(q);
      return CmdResult(true, 'Playing "$q" on YouTube', 'youtube');
    }),
    (_fm(r'(?:search|google|look up|search for|search google for) (.+)'), (m, o) {
      final pm = RegExp(r'(?:search google for|search for|search|google|look up)\W+(.+)$', caseSensitive: false).firstMatch(o);
      final q = pm == null ? m[1]! : pyRstrip(pm[pm.groupCount]!.trim(), '.!?').trim();
      openUrl('https://www.google.com/search?q=${Uri.encodeQueryComponent(q.isEmpty ? m[1]! : q)}');
      return CmdResult(true, 'Searching Google for "${q.isEmpty ? m[1] : q}"', 'search');
    }),
    (_fm(r'(?:open|launch|start|run) (.+)'), (m, o) => openAnything(m[1]!)),
  ];

    static RegExp _fm(String p) => RegExp('^(?:$p)\$');

  Future<CmdResult?> _run(String cmd, String original) async {
    for (final (rx, fn) in _commands) {
      final m = rx.firstMatch(cmd);
      if (m == null) continue;
      try {
        final r = await fn(m, original);
        if (r != null) return r;
      } catch (e) {
        return CmdResult(false, 'Failed: $e', 'error');
      }
    }
    return null;
  }

  CmdResult openAnything(String name) {
    name = name.trim();
    final low = name.toLowerCase();
    if (const ['on-screen keyboard', 'on screen keyboard', 'touch keyboard', 'osk'].any(low.contains)) {
      return CmdResult(false, 'On-screen keyboard is disabled', 'blocked');
    }
    name = name.replaceFirst(RegExp(r'^(the|my|a)\s+'), '');
    name = name.replaceFirst(RegExp(r'\s+(website|site|web site)$'), '');
    name = name.replaceAll(RegExp(r'\s+dot\s+'), '.');
    name = name.replaceFirstMapped(RegExp(r'^([\w-]+(?:\.[\w-]+)*) (com|org|net|io|dev|ai|app|in|co|co\.uk|edu|gov)$'), (m) => '${m[1]}.${m[2]}');
    final app = apps.find(name);
    // phones: an installed app wins over its website (YouTube app, not youtube.com)
    if (app != null) {
      op('launch_app', args: [app.$2]);
      return CmdResult(true, 'Opening ${pyTitle(app.$1)}', 'launch');
    }
    if (websites.containsKey(name)) {
      openUrl(websites[name]!);
      return CmdResult(true, 'Opened ${pyTitle(name)}', 'web');
    }
    if (RegExp(r'^[\w-]+(\.[\w-]+)+(/\S*)?$').hasMatch(name)) {
      openUrl('https://$name');
      return CmdResult(true, 'Opened $name', 'web');
    }
    return CmdResult(false, 'Couldn\'t find an app or site called "$name"', 'launch');
  }

  /// Open the n-th YouTube result directly (so it plays), else the results page.
  Future<String> playYoutube(String query, [int nth = 1]) async {
    var url = '${core.config('web.youtube_search') ?? 'https://www.youtube.com/results?search_query='}${Uri.encodeQueryComponent(query)}';
    try {
      final html = fetch == null ? null : await fetch!(Uri.parse(url)).timeout(const Duration(seconds: 3));
      if (html != null) {
        var ids = RegExp(r'"videoRenderer":\{"videoId":"([\w-]{11})"').allMatches(html).map((m) => m[1]!).toSet().toList();
        if (ids.isEmpty) ids = RegExp(r'"videoId":"([\w-]{11})"').allMatches(html).map((m) => m[1]!).toSet().toList();
        if (ids.isNotEmpty) url = 'https://www.youtube.com/watch?v=${ids[(nth < 1 ? 1 : nth).clamp(1, ids.length) - 1]}';
      }
    } catch (_) {}
    openUrl(url);
    return url;
  }

  /// A plain GET with dart:io (used for the YouTube lookup).
  static Future<String?> httpGet(Uri url) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await c.getUrl(url);
      req.headers.set('User-Agent', 'Mozilla/5.0');
      req.headers.set('Accept-Language', 'en-US,en;q=0.9');
      final r = await req.close();
      return await r.transform(utf8.decoder).join();
    } finally {
      c.close(force: true);
    }
  }
}

// ------------------------------------------------------------------ on-screen matcher
class ScreenElement {
  final String name, ctype;
  final List<int> rect; // l, t, r, b
  final int control, depth;
  ScreenElement(this.name, this.ctype, this.rect, this.control, this.depth);
  int get area => (rect[2] - rect[0]).clamp(0, 1 << 30) * (rect[3] - rect[1]).clamp(0, 1 << 30);
}

class ScreenMatcher {
  static const typeWords = {
    'button': {'ButtonControl', 'SplitButtonControl'}, 'link': {'HyperlinkControl'},
    'field': {'EditControl', 'ComboBoxControl', 'DocumentControl'}, 'box': {'EditControl', 'ComboBoxControl'},
    'search': {'EditControl', 'ComboBoxControl'}, 'input': {'EditControl'}, 'textbox': {'EditControl'},
    'tab': {'TabItemControl'}, 'menu': {'MenuItemControl'}, 'checkbox': {'CheckBoxControl'},
    'option': {'ListItemControl', 'RadioButtonControl', 'MenuItemControl'}, 'item': {'ListItemControl', 'TreeItemControl'},
    'video': {'HyperlinkControl', 'ListItemControl'}, 'result': {'HyperlinkControl', 'ListItemControl'},
    'image': {'ImageControl'}, 'picture': {'ImageControl'}, 'thumbnail': {'HyperlinkControl', 'ImageControl'},
  };
  static const ordinals = {
    'first': 0, '1st': 0, 'second': 1, '2nd': 1, 'third': 2, '3rd': 2, 'fourth': 3, '4th': 3, 'fifth': 4, '5th': 4,
    'sixth': 5, 'last': -1, 'pehla': 0, 'pehli': 0, 'doosra': 1, 'doosri': 1, 'teesra': 2, 'teesri': 2,
  };
  static const caption = {'minimize', 'minimise', 'maximize', 'maximise', 'restore', 'close', 'restore down', 'system'};

  static Set<String> _typeFilter(String q) {
    q = q.toLowerCase();
    final types = <String>{};
    typeWords.forEach((w, ts) {
      if (RegExp('\\b${w}s?\\b').hasMatch(q)) types.addAll(ts);
    });
    return types;
  }

  static String _stripWords(String query) {
    var q = query.toLowerCase().replaceAll(
        RegExp(r'\b(click|tap|double|right|select|choose|hit|open|play|watch|the|a|an|on|in|at|of|to|this|that|please|button|link|field|box|tab|icon|option|item|'
            r'menu|video|result|thumbnail|image|picture|section|area|side|corner|one|wala|wali|pe|par)\b'),
        ' ');
    for (final w in [...ordinals.keys, 'top', 'bottom', 'left', 'right', 'upper', 'lower', 'middle', 'center', 'centre', 'first', 'last']) {
      q = q.replaceAll(RegExp('\\b${RegExp.escape(w)}\\b'), ' ');
    }
    return collapseWs(q);
  }

  static (String?, String?, int?) _spatial(String query) {
    final q = query.toLowerCase();
    final vert = RegExp(r'\b(top|upper|above|upar)\b').hasMatch(q) ? 'top' : (RegExp(r'\b(bottom|lower|below|neeche)\b').hasMatch(q) ? 'bottom' : null);
    final horiz = RegExp(r'\b(left|baayen|baaye)\b').hasMatch(q) ? 'left' : (RegExp(r'\b(right|daayen|daaye)\b').hasMatch(q) ? 'right' : null);
    int? ordinal;
    for (final e in ordinals.entries) {
      if (RegExp('\\b${RegExp.escape(e.key)}\\b').hasMatch(q)) {
        ordinal = e.value;
        break;
      }
    }
    final n = RegExp(r'\b(?:number|no\.?|#)\s*(\d+)\b').firstMatch(q);
    if (n != null) ordinal = int.parse(n[1]!) - 1;
    return (vert, horiz, ordinal);
  }

  static double _scoreName(String target, String name) {
    if (target.isEmpty) return 0;
    final n = name.toLowerCase();
    if (target == n) return 1;
    if (n.contains(target)) return 0.85 + 0.1 * (target.length / (n.isEmpty ? 1 : n.length));
    final tw = target.split(' ').toSet();
    final nw = RegExp(r'\w+').allMatches(n).map((m) => m[0]!).toSet();
    final overlap = tw.intersection(nw).length / (tw.isEmpty ? 1 : tw.length);
    final cut = n.length > target.length + 10 ? n.substring(0, target.length + 10) : n;
    final r = seqRatio(target, cut) * 0.7;
    return overlap * 0.8 > r ? overlap * 0.8 : r;
  }

  /// (element, why) or (null, reason)
  static (ScreenElement?, String) find(String query, List<ScreenElement> elements) {
    if (elements.isEmpty) return (null, "I can't read this window's controls.");
    final types = _typeFilter(query);
    final target = _stripWords(query);
    final (vert, horiz, ordinal) = _spatial(query);
    final ql = query.toLowerCase();
    if (!caption.any(ql.contains)) elements = elements.where((e) => !caption.contains(e.name.toLowerCase())).toList();
    var pool = elements.where((e) => types.isEmpty || types.contains(e.ctype)).toList();
    if (types.isNotEmpty && pool.isEmpty) return (null, "I don't see anything like that on this screen.");
    if (ql.contains('video') || ql.contains('thumbnail') || ql.contains('result')) {
      pool = pool.where((e) => e.name.length > 15 && e.area > 2500).toList();
      if (pool.isEmpty) return (null, "I don't see any videos on this screen.");
    }
    if (target.isNotEmpty) {
      final scored = stableSorted([for (final e in pool) (_scoreName(target, e.name), e)], (a, b) => b.$1.compareTo(a.$1));
      final top = scored.isEmpty ? 0.0 : scored.first.$1;
      final best = top >= 0.5 ? [for (final s in scored) if (s.$1 >= (top - 0.05 > 0.5 ? top - 0.05 : 0.5)) s.$2] : <ScreenElement>[];
      if (best.isEmpty) return (null, 'I couldn’t find “$target” on this screen.');
      pool = best;
    }
    if (vert != null || horiz != null || ordinal != null) {
      int cmpRows(ScreenElement a, ScreenElement b) {
        final ra = pyRound(a.rect[1] / 60), rb = pyRound(b.rect[1] / 60);
        return ra != rb ? ra - rb : a.rect[0] - b.rect[0];
      }

      var rows = stableSorted(pool, cmpRows);
      if (vert == 'bottom') {
        rows = stableSorted(pool, (a, b) {
          final ra = -pyRound(a.rect[3] / 60), rb = -pyRound(b.rect[3] / 60);
          return ra != rb ? ra - rb : a.rect[0] - b.rect[0];
        });
      }
      if (horiz == 'right') {
        rows = stableSorted(rows, (a, b) {
          final ra = pyRound((vert != 'bottom' ? a.rect[1] : -a.rect[3]) / 60), rb = pyRound((vert != 'bottom' ? b.rect[1] : -b.rect[3]) / 60);
          return ra != rb ? ra - rb : b.rect[2] - a.rect[2];
        });
      }
      var idx = ordinal ?? 0;
      if (idx < 0) idx = rows.length + idx;
      if (idx >= 0 && idx < rows.length) return (rows[idx], 'position');
      return (null, 'There are only ${rows.length} matching items here.');
    }
    final best = stableSorted(pool, (a, b) => a.depth != b.depth ? a.depth - b.depth : b.area - a.area);
    return (best.first, 'name');
  }

  /// Kotlin sends the accessibility nodes; -> {"index", "why"}.
  static Map<String, dynamic> findJson(String query, String nodesJson) {
    final nodes = jsonDecode(nodesJson) as List;
    final els = <ScreenElement>[];
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i] as Map;
      els.add(ScreenElement('${n['name'] ?? ''}', '${n['type'] ?? 'ButtonControl'}',
          [for (final v in (n['rect'] as List)) (v as num).toInt()], i, ((n['depth'] as num?) ?? 5).toInt()));
    }
    final (el, why) = find(query, els);
    return {'index': el?.control ?? -1, 'why': why};
  }
}
