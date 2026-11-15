// Text rules from core/intents, exactly as specified in core/README.md §4 (the Python
// reference is engine/src/brain/phone_intents.py, hinglish.py, ai/agent_controller.py,
// life/tasks.py, brain/memory.py, voice/voice_listener.py).
import 'core_data.dart';
import 'py.dart';

class Rules {
  final CoreData core;
  Rules(this.core);

  // ================================================================ §4.3 command text
  static final _quotesPunct = RegExp('["“”.,!?;:()]+');

  static String normalizeText(String text) {
    var t = text.toLowerCase().trim();
    t = t.replaceAll('’', "'").replaceAll('-', ' ');
    t = t.replaceAll(_quotesPunct, ' ');
    return collapseWs(t);
  }

  String plain(String cmd) {
    var out = core.strip('polite_prefix', cmd).trim();
    out = core.strip('polite_suffix', out).trim();
    return out.isEmpty ? cmd : out;
  }

  String plainOriginal(String original) {
    final out = core.strip('polite_prefix_original', original).trim();
    return out.isEmpty ? original : out;
  }

  String assistantPolite(String text) => core.strip('assistant_polite', text.trim());

  // ================================================================ §4.4 ordinals
  static bool _isDigits(String s) => s.isNotEmpty && RegExp(r'^[0-9]+$').hasMatch(s);

  (String, int?) ordinal(String cmd) {
    final words = (core.config('ordinals') as Map?) ?? const {};
    for (final (_, m) in core.matches('ordinal', cmd)) {
      final tok = CoreData.group(m, 'n') ?? '';
      final n = _isDigits(tok) ? int.parse(tok) : (words[tok] as num?)?.toInt();
      final keep = CoreData.group(m, 'keep') ?? '';
      final rest = pyStrip(collapseRaw('${cmd.substring(0, m.start)}$keep ${cmd.substring(m.end)}'), ' ,');
      if (n != null && n != 0 && rest.isNotEmpty) return (rest, n);
    }
    return (cmd, null);
  }

  /// re.sub(r"\s+", " ", s) without trimming
  static String collapseRaw(String s) => s.replaceAll(RegExp(r'\s+'), ' ');

  // ================================================================ §4.5 play requests
  String? playRequest(String cmd) {
    final ordinals = ((core.config('ordinals') as Map?) ?? const {}).keys.cast<String>();
    final topicless = {...core.words('play_topicless_words'), ...ordinals};
    final reject = core.words('play_reject').toSet();
    for (final (_, m) in core.matches('play', cmd)) {
      var q = core.strip('play_filler_prefix', (CoreData.group(m, 'q') ?? '').trim());
      q = core.strip('play_suffix', q).trim();
      q = core.rewrite('play_fixes', q);
      final words = q.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
      if (words.every((w) => topicless.contains(w) || _pyIsDigit(w))) return null;
      if (q.isNotEmpty && !reject.contains(q)) return q;
    }
    return null;
  }

  /// The pipeline the assistant and the conformance suite use.
  ({String? q, int? n, String rest}) playPipeline(String text) {
    final (rest, n) = ordinal(plain(normalizeText(text)));
    return (q: playRequest(rest), n: n, rest: rest);
  }

  // ================================================================ §4.6 wake word
  List<String> wakeVariants(String agentName, List<String> wakeWords) {
    final name = normalizeText(agentName);
    final set = <String>{
      ...wakeWords.map(normalizeText),
      ...List<String>.from((core.config('vocab.wake.builtin') as List?) ?? const []),
      if (name.isNotEmpty) ...[name, name.replaceAll(' ', '')],
    };
    final out = set.toList()
      ..sort((a, b) => a.length != b.length ? b.length - a.length : a.compareTo(b));
    return out;
  }

  String soundKey(String word) {
    var w = word.toLowerCase();
    for (final pair in (core.config('vocab.wake.phonetic') as List?) ?? const []) {
      w = w.replaceAll((pair as List)[0] as String, pair[1] as String);
    }
    w = w.replaceAllMapped(RegExp(r'(.)\1+'), (m) => m[1]!);
    return w.replaceFirst(RegExp(r'h$'), '');
  }

  (bool, String) stripWake(String text, {String agentName = 'Snapy', List<String> wakeWords = const ['snapy', 'snap']}) {
    final norm = normalizeText(text);
    final filler = '^${core.fragment('wake_filler')}';
    final suffix = RegExp.escape((core.config('vocab.wake.optional_suffix') as String?) ?? ' air');
    for (final v in wakeVariants(agentName, wakeWords)) {
      final m = RegExp('$filler${RegExp.escape(v)}(?:$suffix)?\\b\\s*(.*)\$').firstMatch(norm);
      if (m != null) return (true, m[1]!.trim());
    }
    final name = normalizeText(agentName);
    final builtin = List<String>.from((core.config('vocab.wake.builtin') as List?) ?? const []).toSet();
    final minLen = ((core.config('vocab.wake.fuzzy_min_name_len') as num?) ?? 4).toInt();
    if (name.isNotEmpty && !builtin.contains(name) && name.length >= minLen) {
      final m = RegExp('$filler(\\S+(?: \\S+)?)\\s*(.*)\$').firstMatch(norm);
      if (m != null) {
        final cand = m[1]!.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
        final ratio = ((core.config('vocab.wake.fuzzy_min_ratio') as num?) ?? 0.8).toDouble();
        final nameWords = name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
        for (final k in [nameWords, 1]) {
          final c = cand.take(k).join(' ');
          if (seqRatio(soundKey(c), soundKey(name)) >= ratio) {
            return (true, ('${cand.skip(k).join(' ')} ${m[2]}').trim());
          }
        }
      }
    }
    return (false, norm);
  }

  /// The original text minus the wake word (keeps casing for messages / notes).
  String stripWakeOriginal(String raw, {String agentName = 'Snapy', List<String> wakeWords = const ['snapy', 'snap']}) {
    final (heard, rest) = stripWake(raw, agentName: agentName, wakeWords: wakeWords);
    if (!heard) return raw.trim();
    final words = raw.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final nRest = rest.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    if (nRest == 0) return '';
    var start = words.length - nRest; // Python slice semantics for a negative start
    if (start < 0) start = words.length + start;
    return words.sublist(start < 0 ? 0 : start).join(' ');
  }

  // ================================================================ §4.2 Hinglish
  String toLatin(String text) {
    final entries = stableSorted(core.mapDomain('transliteration').entries.toList(),
        (a, b) => b.key.runes.length - a.key.runes.length);
    var out = text;
    for (final e in entries) {
      out = out.replaceAll(e.key, e.value);
    }
    return out;
  }

  String? normalizeCommand(String text) {
    var t = toLatin(text).toLowerCase().trim();
    t = core.rewrite('normalize_punct', t);
    t = core.strip('normalize_prefix', collapseRaw(t)).trim();
    t = core.strip('normalize_suffix', t);
    final hit = core.firstMatch('normalize', t);
    if (hit == null) return null;
    var out = CoreData.replaceWith(hit.$1, hit.$2).trim();
    out = core.rewrite('normalize_fillers', out);
    return out != t ? out : null;
  }

  bool isQuestionOrCreative(String text) => core.anyMatch('question_or_creative', text.trim());

  bool hasDevanagari(String text) => core.anyMatch('script_devanagari', text);

  String detectLang(String text, [String? hint]) {
    if (hasDevanagari(text)) return 'hi';
    final words = RegExp(r'[a-z]+').allMatches(text.toLowerCase()).map((m) => m[0]!).toSet();
    final markers = core.words('hinglish_markers').toSet();
    if (words.intersection(markers).length >= 2) return 'hinglish';
    return hint != null && hint.isNotEmpty && hint != 'en' ? hint : 'en';
  }

  // ================================================================ §4.8 misc
  bool soundsUnfinished(String text) => core.anyMatch('unfinished', text.trim());

  String cleanTitle(String text) {
    var t = core.strip('task_title_prefix', text.trim());
    t = core.strip('task_title_suffix', t);
    final out = pyStrip(t, ' ,.').trim();
    return out.isEmpty ? text.trim() : out;
  }

  // ================================================================ §4.1 phone
  static String clean(String? s) => collapseRaw(pyStrip(s ?? '', ' .,!?:"\'')).trim();

  static const _devDigits = '०१२३४५६७८९';

  /// Python str.isdigit() for ASCII and Devanagari digits.
  static bool _pyIsDigit(String s) => s.isNotEmpty && s.runes.every((r) => (r >= 48 && r <= 57) || _devDigits.contains(String.fromCharCode(r)));

  static int _pyInt(String s) => int.parse(String.fromCharCodes(s.runes.map((r) {
        final i = _devDigits.indexOf(String.fromCharCode(r));
        return i >= 0 ? 48 + i : r;
      })));

  int? _numWords(String s) {
    s = s.trim().toLowerCase();
    if (_pyIsDigit(s)) return _pyInt(s);
    return (((core.config('vocab.numbers.phone') as Map?) ?? const {})[s] as num?)?.toInt();
  }

  int _timerSeconds(int n, String unit) {
    final u = unit.toLowerCase();
    final table = (core.config('vocab.timer_units') as Map?) ?? const {};
    for (final rule in (table['rules'] as List?) ?? const []) {
      if (List<String>.from((rule as Map)['prefixes'] as List).any(u.startsWith)) return n * (rule['seconds'] as num).toInt();
    }
    return n * ((table['default_seconds'] as num?) ?? 60).toInt();
  }

  /// A slot from the original-cased text at the match's offsets. Dart has no group offsets,
  /// so the same (case-insensitive) pattern is run on [t]; it matches at the same place.
  static String? _span(String t, String low, RegExp rx, RegExpMatch m, String group) {
    if (t.length == low.length) {
      final mt = rx.firstMatch(t);
      if (mt != null && mt.start == m.start && mt.end == m.end) return CoreData.group(mt, group);
    }
    return CoreData.group(m, group);
  }

  Map<String, dynamic>? parsePhone(String text, [DateTime? now]) {
    final t = clean(text);
    final low = t.toLowerCase();
    final slots = Map<String, dynamic>.from(core.slotValues('phone') as Map);
    final notNames = List<String>.from(slots['not_names'] as List).toSet();
    for (final (entry, m) in core.matches('phone', low)) {
      final kind = entry.intent;
      String? g(String k) => CoreData.group(m, k);
      switch (kind) {
        case 'whatsapp':
        case 'sms':
          final name = clean(g('name'));
          if (name.isEmpty || notNames.contains(name)) continue;
          return {'kind': kind, 'contact': name, 'text': clean(_span(t, low, entry.rx!, m, 'text'))};
        case 'call':
          final name = clean(g('name'));
          if (name.isEmpty || notNames.contains(name)) continue;
          return {'kind': 'call', 'contact': name, 'video': low.startsWith(slots['video_call_prefix'] as String)};
        case 'alarm':
          final (at, _) = parseWhen(g('when') ?? '', now);
          if (at == null) continue;
          return {'kind': 'alarm', 'hour': at.hour, 'minute': at.minute, 'label': slots['alarm_label']};
        case 'timer':
          final n = _numWords(g('n') ?? '');
          if (n == null || n == 0) continue;
          return {'kind': 'timer', 'seconds': _timerSeconds(n, g('unit') ?? '')};
        case 'navigate':
          final place = clean(_span(t, low, entry.rx!, m, 'place'));
          return place.isNotEmpty ? {'kind': 'navigate', 'place': place} : null;
        case 'torch':
          return {'kind': 'torch', 'on': List<String>.from(slots['torch_on'] as List).contains((g('state') ?? '').toLowerCase())};
        case 'panel':
          final p = (g('panel') ?? '').toLowerCase().replaceAll('-', '');
          return {'kind': 'panel', 'panel': (slots['panel'] as Map)[p] ?? slots['panel_default']};
        case 'type':
          return {'kind': 'type', 'text': clean(_span(t, low, entry.rx!, m, 'text'))};
        case 'tap':
          final target = clean(g('target'));
          if (low.startsWith('open ') && !core.anyMatch('phone_tap_open_ok', target)) return null;
          return target.isNotEmpty ? {'kind': 'tap', 'target': target} : null;
      }
    }
    return null;
  }

  bool isPhoneYes(String text) => core.anyMatch('phone_yes', text.trim());
  bool isPhoneNo(String text) => core.anyMatch('phone_no', text.trim());

  // ================================================================ §4.9 time parser
  Map<String, dynamic> get _time => Map<String, dynamic>.from((core.config('vocab.time') as Map?) ?? const {});
  Map<String, dynamic> get _num => Map<String, dynamic>.from((core.config('vocab.numbers.time') as Map?) ?? const {});

  double? _numVal(String s) {
    s = s.trim().toLowerCase();
    final d = double.tryParse(s);
    if (d != null && RegExp(r'^[0-9.]+$').hasMatch(s)) return d;
    return (_num[s] as num?)?.toDouble();
  }

  double? _unitMinutes(String u) {
    final units = Map<String, dynamic>.from((_time['unit_minutes'] as Map?) ?? const {});
    final low = u.toLowerCase();
    u = low != 's' ? pyRstrip(low, 's') : 's';
    if (units.containsKey(u)) return (units[u] as num).toDouble();
    if (u.isEmpty) return null;
    final short = u.length > 3 ? u.substring(0, 3) : u;
    return (units[short] as num?)?.toDouble();
  }

  static DateTime _at(DateTime day, int h, int m) => DateTime(day.year, day.month, day.day, h, m);

  DateTime _clock(int h, String? mm, String? ampm, DateTime now, DateTime? day) {
    var m = int.tryParse(mm ?? '') ?? 0;
    if (ampm != null && ampm.isNotEmpty) {
      ampm = ampm.replaceAll('.', '').toLowerCase();
      if (ampm.startsWith('p') && h < 12) h += 12;
      if (ampm.startsWith('a') && h == 12) h = 0;
    } else {
      ampm = null;
    }
    final base = day ?? DateTime(now.year, now.month, now.day);
    final cand = _at(base, h % 24, m);
    if (day == null && ampm == null && h <= 12) {
      var options = h < 12 ? [cand, cand.add(const Duration(hours: 12))] : [cand];
      final afh = List<num>.from((_time['afternoon_first_hours'] as List?) ?? const [1, 6]);
      if (afh[0] <= h && h <= afh[1]) options = [cand.add(const Duration(hours: 12)), cand];
      for (final c in options) {
        if (c.isAfter(now)) return c;
      }
      return _addDays(options[0], 1);
    }
    if (day == null && !cand.isAfter(now)) return _addDays(cand, 1);
    return cand;
  }

  /// Calendar-day arithmetic in local time (DST-safe, like Python's naive datetimes).
  static DateTime _addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n, d.hour, d.minute, d.second, d.millisecond, d.microsecond);

  static DateTime _addMinutes(DateTime d, double minutes) {
    // Python naive datetime + timedelta: wall-clock arithmetic
    final us = (minutes * 60e6).round();
    final base = DateTime.utc(d.year, d.month, d.day, d.hour, d.minute, d.second, d.millisecond, d.microsecond);
    final r = base.add(Duration(microseconds: us));
    return DateTime(r.year, r.month, r.day, r.hour, r.minute, r.second, r.millisecond, r.microsecond);
  }

  (DateTime?, String) parseWhen(String text, [DateTime? now]) {
    now ??= DateTime.now();
    final t = ' ${text.trim()} ';
    final low = t.toLowerCase();
    final weekdays = List<String>.from((_time['weekdays'] as List?) ?? const []);
    final numrx = '(\\d+(?:\\.\\d+)?|${_num.keys.join('|')})';
    DateTime? when;
    (int, int)? span;

    for (final src in [
      '\\b(?:in|after)\\s+$numrx\\s*(seconds?|secs?|minutes?|mins?|m|hours?|hrs?|h)\\b',
      '\\b$numrx\\s*(seconds?|minutes?|mins?|ghante|hours?|hrs?)\\s+(?:baad|bad|later|from now)\\b',
    ]) {
      final m = RegExp(src).firstMatch(low);
      if (m != null) {
        final n = _numVal(m[1]!);
        final mins = _unitMinutes(m[2]!.replaceAll('ghante', 'hour'));
        if (n != null && mins != null && mins != 0 && when == null) {
          when = _addMinutes(now, n * mins);
          span = (m.start, m.end);
        }
      }
    }

    DateTime? day;
    final today = DateTime(now.year, now.month, now.day);
    final dm = RegExp(r'\b(tomorrow|kal|day after tomorrow|tonight|this evening|this afternoon|this morning|shaam ko|subah)\b')
        .firstMatch(low);
    if (dm != null) {
      day = _addDays(today, (((_time['day_offsets'] as Map?) ?? const {})[dm[1]] as num?)?.toInt() ?? 0);
    }
    final wm = RegExp('\\b(?:on |next |this )?(${weekdays.join('|')})\\b').firstMatch(low);
    if (wm != null && day == null) {
      final target = weekdays.indexOf(wm[1]!);
      var delta = (target - (now.weekday - 1)) % 7;
      if (delta == 0) delta = 7;
      day = _addDays(today, delta);
    }

    final cm = RegExp(r'\b(?:at|by|@)\s*(\d{1,2})(?::|\.)?(\d{2})?\s*(a\.?m\.?|p\.?m\.?)?(?=\W)').firstMatch(low) ??
        RegExp(r'\b(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)(?=\W)').firstMatch(low) ??
        RegExp(r'\b(\d{1,2}):(\d{2})()(?=\W)').firstMatch(low);
    if (cm != null && when == null) {
      final h = int.parse(cm[1]!);
      if (h <= 23) {
        when = _clock(h, cm[2], cm[3], now, day);
        span = (cm.start, cm.end);
      }
    }
    final nm = RegExp(r'\b(?:at )?(noon|midday|midnight)\b').firstMatch(low);
    if (nm != null && when == null) {
      when = _at(day ?? today, nm[1] == 'midnight' ? 0 : 12, 0);
      if (!when.isAfter(now)) when = _addDays(when, 1);
      span = (nm.start, nm.end);
    }

    if (when == null && day != null) {
      final defaults = (_time['day_default_hours'] as Map?) ?? const {};
      var hour = ((defaults[dm != null ? dm[1] : ''] ?? _time['fallback_hour'] ?? 9) as num).toInt();
      final pod = RegExp(r'\b(subah|morning|dopahar|afternoon|shaam|evening|raat|night)\b').firstMatch(low);
      if (pod != null) hour = ((_time['part_of_day_hours'] as Map)[pod[1]] as num).toInt();
      when = _at(day, hour, 0);
      if (!when.isAfter(now)) when = _addMinutes(now, ((_time['past_day_fallback_min'] as num?) ?? 30).toDouble());
    }

    var rest = t;
    if (span != null) rest = '${rest.substring(0, span.$1)} ${rest.substring(span.$2)}';
    if (when != null) {
      for (final src in [
        r'\b(day after tomorrow|tomorrow|kal|tonight|this evening|this afternoon|this morning|shaam ko|subah|'
            r'aaj raat|raat ko|(?:in the )?(?:morning|evening|afternoon|night)|shaam|dopahar|raat)\b',
        '\\b(?:on |next |this )?(${weekdays.join('|')})\\b',
      ]) {
        rest = rest.replaceAll(RegExp(src, caseSensitive: false), ' ');
      }
    }
    rest = pyStrip(collapseRaw(rest), ' ,.');
    return (when, rest);
  }

  String humanTime(Object? when, [DateTime? now]) {
    if (when == null || when == '') return '';
    now ??= DateTime.now();
    final w = when is DateTime ? when : parseIsoLocal(when as String);
    if (w == null) return '';
    final hm = clock12(w);
    final today = DateTime(now.year, now.month, now.day);
    final wd = DateTime(w.year, w.month, w.day);
    if (wd == today) return 'today at $hm';
    if (wd == _addDays(today, 1)) return 'tomorrow at $hm';
    return '${weekdayShort[w.weekday - 1]} ${w.day.toString().padLeft(2, '0')} ${monthShort[w.month - 1]} at $hm';
  }

  // ================================================================ §4.7 memory rules
  bool isSecret(String? text) => core.anyMatch('memory_secret', text ?? '');

  bool memorySelf(String text) => core.anyMatch('memory_self', text);

  /// Every matching memory_extract entry -> {key, text, category, importance} (+ groups).
  List<Map<String, dynamic>> extractRules(String text) {
    final out = <Map<String, dynamic>>[];
    for (final e in core.entries('memory_extract')) {
      final m = e.rx!.firstMatch(text);
      if (m == null) continue;
      final groups = <String>[
        for (var i = 1; i <= m.groupCount; i++)
          if ((m.group(i) ?? '').isNotEmpty) pyRstrip(m.group(i)!.trim(), '.'),
      ];
      if (groups.isEmpty) continue;
      var tmpl = e['template'] as String;
      for (var i = 0; i < groups.length; i++) {
        tmpl = tmpl.replaceAll('{$i}', groups[i]);
      }
      out.add({'key': e['key'], 'text': tmpl, 'category': e['category'], 'importance': e['importance'], 'groups': groups});
    }
    return out;
  }

  /// memory_explicit slot fact, or null.
  String? explicitFact(String text) {
    final e = core.entries('memory_explicit').first;
    final m = e.rx!.firstMatch(text.trim());
    if (m == null || m.start != 0) return null;
    return CoreData.group(m, 'fact');
  }
}
