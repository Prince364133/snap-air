// Meeting notes from text segments (the phone's recognizer) and the daily briefing.
// Python reference: engine/src/life/meeting.py, engine/src/brain/briefing.py (phone subset:
// no desktop activity tracking, no weather).
import 'dart:convert';
import 'dart:math' as math;

import 'brain.dart';
import 'core_data.dart';
import 'py.dart';
import 'stores.dart';

class MeetingRecorder {
  final CoreData core;
  final NoteStore notes;
  final TaskStore tasks;
  final MemoryStore memory;
  final BrainRouter? llm;
  final void Function(Map<String, dynamic> state) onUpdate;
  final Clock now;

  bool recording = false;
  DateTime? started;
  String? title;
  final List<Map<String, dynamic>> segments = []; // {t, who, text}
  final List<Map<String, dynamic>> bookmarks = []; // {t, label}
  DateTime lastSpeech = DateTime.now();
  static const windowS = 20;
  static const silenceStopS = 20 * 60;

  MeetingRecorder(this.core, this.notes, this.tasks, this.memory, this.llm, {required this.onUpdate, Clock? clock})
      : now = clock ?? DateTime.now;

  int elapsed() => started != null && recording ? now().difference(started!).inSeconds : 0;

  Map<String, dynamic> state() => {
        'recording': recording,
        'title': title,
        'elapsed': elapsed(),
        'live': segments.isNotEmpty ? '${segments.last['who']}: ${segments.last['text']}' : '',
        'words': segments.fold<int>(0, (a, s) => a + (s['text'] as String).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length),
        'bookmarks': bookmarks.length,
        'error': null,
      };

  bool start({String? title}) {
    if (recording) return false;
    recording = true;
    started = now();
    lastSpeech = now();
    this.title = title;
    segments.clear();
    bookmarks.clear();
    onUpdate(state());
    return true;
  }

  Map<String, dynamic>? bookmark([String label = '']) {
    if (!recording) return null;
    final b = {'t': elapsed(), 'label': label.trim().isEmpty ? 'Bookmark' : label.trim()};
    bookmarks.add(b);
    onUpdate(state());
    return b;
  }

  static final _wordish = RegExp(r'[A-Za-z0-9À-￿]{2,}');

  /// Already-transcribed speech -> a transcript line. The phone mic hears everyone: who = "Room".
  bool addText(String source, String text) {
    text = text.trim();
    if (!recording || !_wordish.hasMatch(text)) return false;
    lastSpeech = now();
    segments.add({'t': elapsed(), 'who': const {'mic': 'You', 'system': 'Others'}[source] ?? source, 'text': text});
    onUpdate(state());
    return true;
  }

  bool get silentTooLong => recording && now().difference(lastSpeech).inSeconds > silenceStopS;

  static String _mmss(int t) => '${(t ~/ 60).toString().padLeft(2, '0')}:${(t % 60).toString().padLeft(2, '0')}';

  String transcript() {
    final lines = <String>[];
    final marks = stableSorted(bookmarks, (a, b) => (a['t'] as int) - (b['t'] as int));
    for (final s in segments) {
      while (marks.isNotEmpty && (marks.first['t'] as int) <= (s['t'] as int) + windowS) {
        final b = marks.removeAt(0);
        lines.add('[${_mmss(b['t'] as int)}] ★ ${b['label']}');
      }
      lines.add('[${_mmss(s['t'] as int)}] ${s['who']}: ${s['text']}');
    }
    for (final b in marks) {
      lines.add('[${_mmss(b['t'] as int)}] ★ ${b['label']}');
    }
    return lines.join('\n');
  }

  /// No-AI fallback: likely action items and decisions (core/intents meeting_* domains).
  Map<String, dynamic> heuristicNotes() {
    final actions = <Map<String, dynamic>>[], decisions = <String>[];
    for (final s in segments) {
      for (var sent in (s['text'] as String).split(RegExp(r'(?<=[.!?])\s+'))) {
        sent = sent.trim();
        if (sent.length < 8) continue;
        if (core.anyMatch('meeting_decision_hint', sent)) {
          decisions.add(sent);
        } else if (core.anyMatch('meeting_action_hint', sent)) {
          final mine = s['who'] == 'You' && core.anyMatch('meeting_mine', sent);
          actions.add({'task': sent, 'owner': mine ? 'me' : 'unassigned', 'due': '', 'mine': mine});
        }
      }
    }
    final words = segments.fold<int>(0, (a, s) => a + (s['text'] as String).split(RegExp(r'\s+')).length);
    return {
      'title': '',
      'summary': ['${segments.length} transcript segments, $words words (AI summary unavailable).'],
      'key_points': <String>[],
      'decisions': decisions.take(6).toList(),
      'action_items': actions.take(8).toList(),
    };
  }

  Future<Map<String, dynamic>?> summarize(String transcript) async {
    if (llm == null || transcript.split(RegExp(r'\s+')).length < 12 || !await llm!.ready()) return null;
    final words = transcript.split(RegExp(r'\s+'));
    var text = transcript;
    if (words.length > 1100) {
      final parts = <String>[];
      for (var i = 0; i < words.length; i += 1100) {
        parts.add(await llm!.chatText([
          {'role': 'system', 'content': 'Compress this meeting transcript part into terse factual bullet points, keeping who said what, names, numbers, decisions and commitments.'},
          {'role': 'user', 'content': words.sublist(i, math.min(i + 1100, words.length)).join(' ')},
        ], maxTokens: 300));
      }
      text = parts.join('\n');
    }
    return llm!.chatJson([
      {'role': 'system', 'content': core.prompt('meeting_summary')},
      {'role': 'user', 'content': text.length > 9000 ? text.substring(0, 9000) : text},
    ], Map<String, dynamic>.from(core.promptJson['meeting_summary.schema'] as Map), maxTokens: 700);
  }

  Future<Map<String, dynamic>?> stop() async {
    if (!recording) return null;
    recording = false;
    onUpdate(state());
    return finish();
  }

  Future<Map<String, dynamic>> finish() async {
    final st = started ?? now();
    final duration = now().difference(st).inSeconds;
    final tx = transcript();
    if (segments.isEmpty) {
      started = null;
      return {'note': null, 'actions': <dynamic>[], 'title': title ?? 'Meeting', 'empty': true};
    }
    Map<String, dynamic>? result;
    var usedAi = false;
    try {
      result = await summarize(tx);
      usedAi = result != null && result.isNotEmpty;
    } catch (_) {
      result = null;
    }
    if (result == null || result.isEmpty) result = heuristicNotes();
    final t = (result['title'] as String?)?.isNotEmpty == true
        ? result['title'] as String
        : (title ?? 'Meeting ${st.hour.toString().padLeft(2, '0')}:${st.minute.toString().padLeft(2, '0')}');
    final names = {for (final n in [memory.profile['name'], memory.profile['preferred_name']]) if (n is String && n.isNotEmpty) n.toLowerCase()};
    final actions = <Map<String, dynamic>>[];
    var i = 0;
    for (final a in (result['action_items'] as List?) ?? const []) {
      final m = Map<String, dynamic>.from(a as Map);
      final task = ((m['task'] ?? '') as String).trim();
      if (task.isEmpty) {
        i++;
        continue;
      }
      final owner = ((m['owner'] ?? 'unassigned') as String).trim();
      final mine = m['mine'] == true || {'me', 'i', 'myself', ...names}.contains(owner.toLowerCase());
      actions.add({'id': 'a$i', 'task': task, 'owner': owner, 'due': m['due'] ?? '', 'mine': mine, 'status': 'pending'});
      i++;
    }
    final summary = List<String>.from(((result['summary'] as List?) ?? const []).map((e) => '$e'));
    final note = notes.add(summary.take(2).join(' ').isEmpty ? 'Meeting notes' : summary.take(2).join(' '), kind: 'meeting', extra: {
      'title': t,
      'summary': summary,
      'key_points': result['key_points'] ?? <dynamic>[],
      'decisions': result['decisions'] ?? <dynamic>[],
      'actions': actions,
      'bookmarks': [...bookmarks],
      // note.schema.json: transcript is an array of {t, who, text}
      'transcript': [...segments],
      'duration': duration,
      'started': isoMinutes(st),
      'ai_summary': usedAi,
      'review_pending': actions.isNotEmpty,
    });
    final s = summary.join(' ');
    memory.journalAdd('meeting', "Meeting '$t' (${duration ~/ 60} min): ${s.length > 200 ? s.substring(0, 200) : s}");
    started = null;
    return {'note': note, 'title': t, 'actions': actions, 'summary': summary};
  }

  /// decision: accept (creates a task) | not_mine | dismiss
  Map<String, dynamic>? reviewAction(Map<String, dynamic> note, String actionId, String decision) {
    Map<String, dynamic>? task;
    final acts = [for (final a in (note['actions'] as List?) ?? const []) Map<String, dynamic>.from(a as Map)];
    for (final a in acts) {
      if (a['id'] != actionId) continue;
      if (decision == 'accept' && a['status'] == 'pending') {
        task = tasks.addFromText('${a['task']} ${a['due'] ?? ''}'.trim(), source: 'meeting');
      }
      a['status'] = const {'accept': 'accepted', 'not_mine': 'not_mine', 'dismiss': 'dismissed'}[decision] ?? 'pending';
    }
    notes.update(note['id'] as String, {'actions': acts, 'review_pending': acts.any((a) => a['status'] == 'pending')});
    return task;
  }
}

class Briefing {
  final MemoryStore memory;
  final TaskStore tasks;
  final NoteStore notes;
  final Settings settings;
  final String stateFile;
  final String Function(Object? when, [DateTime? now]) humanTime;
  final Clock now;

  Briefing(this.memory, this.tasks, this.notes, this.settings, this.stateFile, this.humanTime, {Clock? clock}) : now = clock ?? DateTime.now;

  static String partOfDay(DateTime n) => n.hour >= 4 && n.hour < 12 ? 'morning' : (n.hour < 17 ? 'afternoon' : 'evening');

  bool shouldGreet([DateTime? at]) {
    final n = at ?? now();
    if (settings.get('daily_greeting') == false || n.hour < 4) return false;
    final st = (readJson(stateFile) as Map?) ?? const {};
    return st['last_greet_day'] != isoDate(n);
  }

  void markGreeted([DateTime? at]) {
    final st = Map<String, dynamic>.from((readJson(stateFile) as Map?) ?? const {});
    st['last_greet_day'] = isoDate(at ?? now());
    writeJson(stateFile, st);
  }

  Map<String, dynamic> build([DateTime? at]) {
    final n = at ?? now();
    final p = memory.profile;
    final name = (p['preferred_name'] as String?)?.isNotEmpty == true ? p['preferred_name'] as String : ((p['name'] as String?) ?? '');
    final hello = 'Good ${partOfDay(n)}${name.isNotEmpty ? ', $name' : ''}!';
    final lines = <String>[];
    final yesterday = isoDate(DateTime(n.year, n.month, n.day - 1));
    final done = tasks.doneOn(yesterday);
    final meetings = notes.onDay(yesterday).where((x) => x['kind'] == 'meeting').toList();
    final bits = <String>[
      if (meetings.isNotEmpty) 'had ${meetings.length} meeting${meetings.length > 1 ? 's' : ''} with notes',
      if (done.isNotEmpty) 'finished ${done.length} task${done.length > 1 ? 's' : ''}',
    ];
    if (bits.isNotEmpty) lines.add('Yesterday you ${bits.join(', ')}.');
    final reviews = notes.items.where((x) => x['review_pending'] == true).toList();
    if (reviews.isNotEmpty) {
      lines.add('${reviews.length} meeting note${reviews.length > 1 ? 's have' : ' has'} action items to review.');
    }
    final open = tasks.openTasks().where((t) => t['source'] != 'timer').toList();
    final today = isoDate(n);
    final nowIso = isoMinutes(n);
    final dueToday = open.where((t) => ((t['remind_at'] ?? '') as String).startsWith(today)).toList();
    final overdue = open
        .where((t) => t['remind_at'] != null && (t['remind_at'] as String).compareTo(nowIso) < 0 && !(t['remind_at'] as String).startsWith(today))
        .toList();
    if (dueToday.isNotEmpty) {
      final first = dueToday.first;
      final more = dueToday.length > 1 ? ' and ${dueToday.length - 1} more' : '';
      lines.add('Today: ${first['title']} ${humanTime(first['remind_at'], n).replaceAll('today ', '')}$more.');
    } else if (overdue.isNotEmpty) {
      lines.add('${overdue.length} task${overdue.length > 1 ? 's are' : ' is'} still open from before — starting with “${overdue.first['title']}”.');
    } else if (open.isNotEmpty) {
      lines.add('You have ${open.length} open task${open.length > 1 ? 's' : ''}.');
    }
    return {'title': hello, 'lines': lines, 'question': 'What would you like to work on today?', 'plan': <dynamic>[], 'weather': null, 'day': today};
  }

  static String spoken(Map<String, dynamic> b) =>
      [b['title'], if ((b['lines'] as List).isNotEmpty) (b['lines'] as List).first, b['question']].join(' ');

  Map<String, dynamic> wrapUp([String? day]) {
    final d = day ?? isoDate(now());
    final dayNotes = notes.onDay(d);
    final done = tasks.doneOn(d);
    final left = tasks.openTasks();
    final lines = <String>[];
    final meetings = dayNotes.where((x) => x['kind'] == 'meeting').toList();
    if (meetings.isNotEmpty) lines.add('Meetings: ${meetings.map((x) => x['title'] ?? 'meeting').join(', ')}.');
    final plain = dayNotes.where((x) => x['kind'] != 'meeting').toList();
    if (plain.isNotEmpty) lines.add('${plain.length} note${plain.length > 1 ? 's' : ''} saved.');
    lines.add('${done.length} task${done.length != 1 ? 's' : ''} done, ${left.length} open${left.isNotEmpty ? ' — next: ${left.first['title']}' : ''}.');
    return {'day': d, 'lines': lines, 'text': lines.join(' ')};
  }

  /// Morning notification text: {"title","text"} or {} when already greeted today.
  String morningBriefJson() {
    if (!shouldGreet()) return '{}';
    final b = build();
    markGreeted();
    final text = (b['lines'] as List).join(' ');
    return jsonEncode({'title': b['title'] ?? 'Good morning', 'text': text.length > 400 ? text.substring(0, 400) : text});
  }
}
