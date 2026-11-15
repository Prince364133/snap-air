// One conversation turn at a time (engine/src/brain/assistant.py, phone subset).
// Routing, fastest first:
//   1. pending offer + yes/no          2. stop words
//   3. rule-based memory extraction    4. fast intents (remember/forget, about me, reminders & tasks,
//      notes, briefing, wrap-up, meeting notes, time/date)
//   5. Hinglish normaliser + phone command grammar (never for questions / "write me…")
//   6. AI conversation with {say, tool, args} streaming   7. built-in replies without an AI
// (Real Count answers and phone intents run before this, in SnapyRuntime.send.)
import 'dart:async';

import 'brain.dart';
import 'commands.dart';
import 'core_data.dart';
import 'life.dart';
import 'py.dart';
import 'rules.dart';
import 'stores.dart';

typedef Emit = void Function(Map<String, dynamic> event);

class Assistant {
  final CoreData core;
  final Rules rules;
  final Settings settings;
  final PhoneCommands agent;
  final MemoryStore memory;
  final TaskStore tasks;
  final NoteStore notes;
  final Briefing briefing;
  final MeetingRecorder meeting;
  final BrainRouter llm;
  final Emit emit;
  final void Function(String text, String lang) say;
  final void Function() stopSpeaking;
  final Clock now;

  final List<Msg> history = [];
  DateTime lastTurn = DateTime.fromMillisecondsSinceEpoch(0);
  Map<String, dynamic>? pending; // {"kind": "action"|"carry"|"meeting_notes", ...}
  String state = 'idle';
  bool working = false;
  bool explainedNoLlm = false;
  Duration learnAfterQuiet = const Duration(seconds: 30);
  final Cancel _cancel = Cancel();
  String? _answering;
  String _partial = '';
  Map<String, dynamic>? interrupted;
  Future<void> _chain = Future.value();
  final List<(String, String)> _learnQueue = [];
  Timer? _learnTimer;
  int _idSeq = 0;

  Assistant(this.core, this.rules, this.settings, this.agent, this.memory, this.tasks, this.notes, this.briefing,
      this.meeting, this.llm, this.emit, this.say, this.stopSpeaking, {Clock? clock})
      : now = clock ?? DateTime.now;

  dynamic _s(String k, [dynamic d]) => settings.get(k) ?? d;

  String _newId() => '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}${(_idSeq++).toRadixString(16)}'.substring(4);

  void setState(String s) {
    if (s != state) {
      state = s;
      emit({'type': 'assistant_state', 'state': s});
    }
  }

  String msg(String role, String text, {bool finalMsg = true, String? id, Map<String, dynamic> extra = const {}}) {
    final mid = id ?? _newId();
    emit({'type': 'chat_message', 'id': mid, 'role': role, 'text': text, 'final': finalMsg, 'ts': epochSeconds(now()), ...extra});
    return mid;
  }

  String reply(String text, String lang, bool speak, [Map<String, dynamic> extra = const {}]) {
    msg('assistant', text, extra: extra);
    if (speak && text.isNotEmpty) say(text, lang);
    memory.recordTurn('assistant', text, lang);
    history.add({'role': 'assistant', 'content': text});
    return text;
  }

  // --------------------------------------------------------------- API
  /// Queue a user turn; a new turn cancels whatever is being said. Completes when handled.
  Future<void> handle(String text, {String source = 'typed', String? lang}) {
    text = text.trim();
    if (text.isEmpty) return Future.value();
    if (state == 'thinking' || state == 'speaking') {
      _cancel.set();
      stopSpeaking();
    }
    final done = Completer<void>();
    _chain = _chain.then((_) async {
      _cancel.clear();
      working = true;
      try {
        await turn(text, source, lang);
      } catch (e) {
        reply('Sorry, something went wrong: $e', 'en', false, {'error': true});
      } finally {
        setState('idle');
        working = false;
        _scheduleLearning();
        done.complete();
      }
    });
    return done.future;
  }

  void interrupt() {
    if (_answering != null) interrupted = {'q': _answering, 'said': _partial.trim(), 't': now()};
    _cancel.set();
    stopSpeaking();
    setState('idle');
  }

  // -------------------------------------------------------------- turn
  Future<void> turn(String text, String source, String? langHint) async {
    final lang = rules.detectLang(text, langHint);
    if (now().difference(lastTurn).inMinutes >= 10) history.clear();
    lastTurn = now();
    final speak = source == 'voice' || _s('speak_typed_replies') == true;
    msg('user', text, extra: {'source': source, 'lang': lang});
    memory.recordTurn('user', text, lang);

    if (pending != null) {
      final p = pending!;
      pending = null;
      if (core.anyMatch('assistant_yes', text.trim())) return _executePending(p, lang, speak);
      if (core.anyMatch('assistant_no', text.trim())) {
        reply('Okay, no problem.', lang, speak);
        return;
      }
    }
    if (core.anyMatch('assistant_stop', text.trim())) {
      setState('idle');
      return;
    }
    try {
      if (memory.extractRules(text).isNotEmpty) emit({'type': 'memory', 'profile': memory.profile, 'memories': memory.memories});
    } catch (_) {}

    final handled = await personal(text, lang, speak);
    if (handled != null) {
      history.add({'role': 'user', 'content': text});
      _learn(text, handled);
      return;
    }

    final polite = rules.assistantPolite(text);
    final cmd = rules.normalizeCommand(polite) ?? polite;
    if (!rules.isQuestionOrCreative(polite)) {
      final r = await agent.execute(cmd);
      if (r.action != 'unknown' && r.action != 'ignored') {
        if (r.action == 'wake') return;
        msg('assistant', r.message, extra: {'ok': r.ok, 'tool': 'desktop', 'command': true});
        emit({'type': 'action_log', 'text': text, 'result': r.message, 'ok': r.ok, 'ts': epochSeconds(now())});
        if (speak && _s('speak_confirmations') == true) say(r.message, lang);
        return;
      }
    }
    if (!await llm.ready()) {
      _noLlmReply(text, lang, speak);
      return;
    }
    await converse(text, lang, speak);
  }

  void _emitTasks() => emit({'type': 'tasks', 'tasks': tasks.openTasks()});

  // --------------------------------------------------- fast intents
  Future<String?> personal(String text, String lang, bool speak) async {
    final t = text.trim();
    var low = t.toLowerCase().replaceAll(RegExp(r'[.!?,]+'), ' ').trim();
    low = low.replaceFirst(RegExp(r'^(hey |ok |okay )?snap\w*\s*'), '').trim();
    final noWake = t.replaceFirst(RegExp(r'^(hey |ok )?snap\W*', caseSensitive: false), '');

    // remember / forget
    if (rules.explicitFact(low) != null && !RegExp(r'\bremind\b|^(please )?remember to\b').hasMatch(low)) {
      final m = memory.explicitRemember(noWake);
      emit({'type': 'memory', 'profile': memory.profile, 'memories': memory.memories});
      return reply(m != null ? 'Got it — I’ll remember that.'.replaceAll('’', "'") : 'Sorry, I couldn\'t save that.', lang, speak, {'tool': 'remember'});
    }
    final fm = RegExp(r'^(?:please )?(?:forget|delete the memory|bhool jao)(?: that| about)?\s+(.+)$').firstMatch(low);
    if (fm != null) {
      final gone = memory.forget(fm[1]!);
      if (gone != null) emit({'type': 'memory', 'profile': memory.profile, 'memories': memory.memories});
      final gt = gone == null ? '' : gone['text'] as String;
      return reply(gone != null ? "Done, I've forgotten that ${gt[0].toLowerCase()}${gt.substring(1)}." : "I don't have anything like that in my memory.",
          lang, speak, {'tool': 'forget'});
    }

    // what do you know about me
    if (RegExp(r'\bwhat (do|did) you (know|remember) about me\b|\bwhat have you learn(ed|t) about me\b|mere baare mein kya (jaante|pata)').hasMatch(low)) {
      emit({'type': 'ui_action', 'action': 'open_drawer', 'tab': 'memory'});
      return reply(memory.aboutMe(), lang, speak, {'tool': 'memory'});
    }

    // meeting bookmark
    if (meeting.recording && RegExp(r'^(mark|bookmark|flag) (that|this|it)\b|^(mark|bookmark) (.+)$').hasMatch(low)) {
      final label = low.replaceFirst(RegExp(r'^(mark|bookmark|flag)( that| this| it)?\s*(as\s+)?'), '').trim();
      meeting.bookmark(label);
      return reply('Marked.', lang, false, {'tool': 'meeting'});
    }

    // timers the phone grammar didn't take ("timer for 5 min")
    final tm = RegExp(r'\b(?:set (?:a |an )?)?timer (?:for )?(\d+|a|an|one|two|three|five|ten|fifteen|twenty|thirty)\s*'
            r'(seconds?|secs?|minutes?|mins?|hours?|hrs?)\b|\b(\d+) (minute|min|second|ghante|hour)\w* ka timer')
        .firstMatch(low);
    if (tm != null) {
      final nTxt = tm[1] ?? tm[3]!, unit = tm[1] != null ? tm[2]! : tm[4]!;
      final n = const {'a': 1, 'an': 1, 'one': 1, 'two': 2, 'three': 3, 'five': 5, 'ten': 10, 'fifteen': 15, 'twenty': 20, 'thirty': 30}[nTxt] ??
          int.parse(nTxt);
      final secs = n * (unit.startsWith('s') ? 1 : (unit.startsWith('h') || unit.startsWith('g') ? 3600 : 60));
      final short = unit.startsWith('s') ? 'sec' : (unit.startsWith('h') || unit.startsWith('g') ? 'hr' : 'min');
      final task = tasks.add('Timer — $n $short', now().add(Duration(seconds: secs)), source: 'timer');
      _emitTasks();
      return reply('Timer set for $n ${pyRstrip(unit, 's')}${n != 1 ? 's' : ''}.', lang, speak, {'tool': 'timer', 'task_id': task['id']});
    }

    // meeting notes (text from the phone's recognizer)
    if (RegExp(r'\b(start|begin)\w*\b.{0,20}\bnotes\b|^take (meeting )?notes( (of|for|from|in|during) (the|this|my) (meeting|call|standup|sync))?$|'
                r'\b(record|transcribe) (the |this |my )?(meeting|call)\b|\bnotes? (lena|lo) shuru|meeting notes (start|shuru)')
            .hasMatch(low) &&
        !RegExp(r'\b(stop|end|finish)\b').hasMatch(low)) {
      if (meeting.recording) return reply("I'm already taking notes.", lang, speak);
      meeting.start();
      emit({'type': 'meeting', ...meeting.state()});
      return reply('Taking meeting notes now. Say “stop taking notes” when it\'s over.', lang, speak, {'tool': 'meeting'});
    }
    if (RegExp(r'\b(stop|end|finish|band)\b.*\b(notes?|recording|meeting)\b|\bmeeting (is )?(over|done|khatam)\b').hasMatch(low) && meeting.recording) {
      reply('Okay, wrapping up the notes — give me a moment.', lang, speak, {'tool': 'meeting'});
      unawaited(finishMeeting(lang, speak));
      return 'meeting stopped';
    }

    // reminders & tasks
    if (RegExp(r'\b(remind|reminder|yaad dila\w*)\b|^(please )?remember to\b').hasMatch(low) ||
        RegExp(r'^(add|create|new) (a )?(task|to ?do)\b').hasMatch(low) ||
        RegExp(r'\badd .+ to (my )?(to ?do|tasks?|list)\b').hasMatch(low)) {
      final src = noWake.replaceFirst(RegExp(r'\s+to (my )?(to ?do( list)?|tasks?|list)$', caseSensitive: false), '');
      final task = tasks.addFromText(src);
      _emitTasks();
      memory.journalAdd('task', 'Task added: ${task['title']}');
      final m = task['remind_at'] != null
          ? "Okay, I'll remind you to ${task['title']} ${rules.humanTime(task['remind_at'], now())}."
          : 'Added “${task['title']}” to your tasks.';
      return reply(m, lang, speak, {'tool': 'add_task'});
    }
    if (RegExp(r"\b(what('s| is| are)?|show|read|list|tell me)\b.*\b(my )?(tasks|to ?dos?|to-?do list)\b|"
            r"what do i (have|need) to do|what('s| is) (left|pending|on my plate)|kya kaam (hai|baaki)|what should i work on")
        .hasMatch(low)) {
      emit({'type': 'ui_action', 'action': 'open_drawer', 'tab': 'tasks'});
      return reply(_tasksText(), lang, speak, {'tool': 'tasks', 'open_tab': 'tasks'});
    }
    final dm = RegExp(r"^(?:mark |i )?(?:finished|done with|completed|i've finished|i have finished|mark)\s+(.+?)(?:\s+(?:as )?(?:done|complete|completed))?$").firstMatch(low) ??
        RegExp(r'^(.+?) (?:is|are) (?:done|finished|complete|ho gaya)$').firstMatch(low);
    if (dm != null && tasks.openTasks().isNotEmpty) {
      final task = tasks.find(dm[1]!);
      if (task != null) {
        tasks.complete(task['id'] as String);
        _emitTasks();
        memory.journalAdd('task', 'Completed: ${task['title']}');
        return reply('Nice — marked “${task['title']}” as done.', lang, speak, {'tool': 'tasks'});
      }
    }

    // notes created today
    if (RegExp(r"^(what|which|show|list|read|tell|open|give)\b.*\bnotes?\b|\btoday'?s notes\b|aaj ke notes|what did we note|notes (we|i) (made|took|created|saved)").hasMatch(low) &&
        !RegExp(r'^(take|add|make|write|save) (a )?note').hasMatch(low)) {
      emit({'type': 'ui_action', 'action': 'open_drawer', 'tab': 'notes', 'filter': 'today'});
      return reply(_notesTodayText(), lang, speak, {'tool': 'notes_today', 'open_tab': 'notes'});
    }
    final note = RegExp(r'^(?:take|add|make|write|save) (?:a )?note(?: (?:that|to|saying))?\s+(.+)$|^note (?:down |that )(.+)$').firstMatch(low);
    if (note != null) {
      final om = RegExp(r'^(?:take|add|make|write|save) (?:a )?note(?: (?:that|to|saying))?\s+(.+)$|^note (?:down |that )(.+)$', caseSensitive: false)
          .firstMatch(noWake.trim());
      final body = pyRstrip(((om?[1] ?? om?[2]) ?? (note[1] ?? note[2]!)).trim(), '.');
      final n = notes.add(body);
      emit({'type': 'note_added', 'note': n});
      return reply('Note saved: “${body.length > 60 ? body.substring(0, 60) : body}”', lang, speak, {'tool': 'add_note'});
    }

    final dr = RegExp(r'^(?:open|show)(?: me)?(?: the| my)? (drawer|panel|today|assistant|notes|tasks|memory|activity|settings|help)(?: (?:tab|panel|drawer))?$').firstMatch(low);
    if (dr != null) {
      final tab = const {'drawer': 'today', 'panel': 'today'}[dr[1]] ?? dr[1]!;
      emit({'type': 'ui_action', 'action': 'open_drawer', 'tab': tab});
      return reply('Opened $tab.', lang, false, {'tool': 'open_panel'});
    }

    // briefing / wrap-up
    if (RegExp(r"\b(brief me|briefing|what'?s (on|up) today|how does my day look|what'?s my day|aaj ka plan|today'?s plan)\b").hasMatch(low) ||
        const ['good morning', 'morning', 'suprabhat'].contains(low)) {
      final b = briefing.build();
      emit({'type': 'briefing', ...b});
      return reply(Briefing.spoken(b), lang, speak, {'tool': 'briefing'});
    }
    if (RegExp(r'\b(wrap ?up|end of (the )?day|what did i (do|get done|work on) today|summari[sz]e my day|aaj kya kiya)\b').hasMatch(low)) {
      final w = briefing.wrapUp();
      final n = now();
      notes.add(w['text'] as String, kind: 'recap', extra: {'title': 'Recap ${weekdayShort[n.weekday - 1]} ${n.day.toString().padLeft(2, '0')} ${monthShort[n.month - 1]}'});
      emit({'type': 'notes', 'notes': notes.items});
      final today = isoDate(n);
      final carry = tasks.openTasks().where((x) => x['remind_at'] != null && ((x['remind_at'] as String).substring(0, 10)).compareTo(today) <= 0).toList();
      var m = "Here's your day: ${w['text']}";
      if (carry.isNotEmpty) {
        pending = {'kind': 'carry', 'ids': [for (final x in carry) x['id']]};
        m += ' Want me to move ${carry.length} unfinished task${carry.length > 1 ? 's' : ''} to tomorrow morning?';
      }
      return reply(m, lang, speak, {'tool': 'wrapup'});
    }

    // time / date
    if (RegExp(r"^(?:(what('s| is) the )?(time|date)( is it)?( now)?|what time is it|time kya hua|aaj kya date hai)$").hasMatch(low)) {
      final n = now();
      final s = "It's ${clock12(n).padLeft(8, '0')}, ${weekdayLong[n.weekday - 1]} ${n.day.toString().padLeft(2, '0')} ${monthLong[n.month - 1]}.".replaceAll(' 0', ' ');
      return reply(s, lang, speak);
    }
    return null;
  }

  String _tasksText() {
    final open = tasks.openTasks();
    if (open.isEmpty) return 'Your task list is clear.';
    final parts = [for (final x in open.take(4)) '${x['title']}${x['remind_at'] != null ? ' (${rules.humanTime(x['remind_at'], now())})' : ''}'];
    final more = open.length > 4 ? ', plus ${open.length - 4} more' : '';
    return 'You have ${open.length} open: ${parts.join('; ')}$more.';
  }

  String _notesTodayText() {
    final day = notes.onDay(isoDate(now()));
    if (day.isEmpty) return 'No notes yet today.';
    final bits = [
      for (final n in day.take(5))
        n['kind'] == 'meeting' ? 'meeting “${n['title'] ?? 'meeting'}”' : ((n['text'] as String).length > 80 ? (n['text'] as String).substring(0, 80) : n['text'] as String),
    ];
    return '${day.length} note${day.length > 1 ? 's' : ''} today: ${bits.join('; ')}.';
  }

  Future<void> _executePending(Map<String, dynamic> p, String lang, bool speak) async {
    switch (p['kind']) {
      case 'action':
        final r = await agent.execute(p['command'] as String);
        reply(r.message, lang, speak, {'tool': 'desktop'});
      case 'carry':
        final n = now();
        final tomorrow9 = DateTime(n.year, n.month, n.day + 1, 9);
        for (final id in p['ids'] as List) {
          tasks.update(id as String, {'remind_at': isoMinutes(tomorrow9)});
        }
        _emitTasks();
        reply('Moved ${(p['ids'] as List).length} to tomorrow at 9. Have a good evening!', lang, speak);
      case 'meeting_notes':
        meeting.start();
        emit({'type': 'meeting', ...meeting.state()});
        reply('Taking notes. Let everyone know notes are being taken.', lang, speak, {'tool': 'meeting'});
    }
  }

  Future<void> finishMeeting(String lang, bool speak) async {
    setState('thinking');
    final res = await meeting.stop();
    emit({'type': 'meeting', ...meeting.state()});
    emit({'type': 'notes', 'notes': notes.items});
    _emitTasks();
    if (res == null) return;
    if (res['empty'] == true) {
      reply("I didn't hear anything to take notes on, so I didn't save a note.", lang, speak, {'tool': 'meeting'});
      setState('idle');
      return;
    }
    final actions = res['actions'] as List;
    final mine = actions.where((a) => (a as Map)['mine'] == true).length;
    var m = 'Your notes for “${res['title']}” are ready';
    if (actions.isNotEmpty) {
      m += '. I found ${actions.length} action item${actions.length != 1 ? 's' : ''}${mine > 0 ? ', $mine for you' : ''} — review them in Notes before I add them to your tasks.';
    } else {
      m += '.';
    }
    final note = res['note'] as Map?;
    if (note != null) emit({'type': 'ui_action', 'action': 'open_note', 'id': note['id']});
    reply(m, lang, speak, {'tool': 'meeting', 'open_tab': 'notes'});
    setState('idle');
  }

  // --------------------------------------------------------------- AI
  String _replyLanguage(String lang, bool speak) {
    if (speak && (lang == 'hi' || lang == 'hinglish')) return core.prompt('reply_language_devanagari');
    return ((core.config('vocab.language_names') as Map?)?[lang] as String?) ?? lang;
  }

  String contextText(String text, String lang, bool speak) {
    final (profile, memories) = memory.contextBlock(text);
    final n = now();
    final open = tasks.openTasks().take(4);
    final today = open.map((x) => '${x['title']}${x['remind_at'] != null ? ' (${rules.humanTime(x['remind_at'], n)})' : ''}').join('; ');
    final mtg = meeting.recording ? ' A meeting is being recorded right now.' : '';
    var note = '';
    final it = interrupted;
    if (it != null && n.difference(it['t'] as DateTime).inSeconds < 90 && it['q'] != text) {
      final said = it['said'] as String;
      note = '\nINTERRUPTED: the user cut you off while you were answering "${it['q']}"'
          '${said.isNotEmpty ? ' (you had said: "${said.length > 200 ? said.substring(0, 200) : said}")' : ''}'
          '. Answer the new message first; then, if the earlier question is still unanswered and relevant, briefly finish it too.';
      interrupted = null;
    }
    final hour = n.hour % 12 == 0 ? 12 : n.hour % 12;
    final time = '${weekdayLong[n.weekday - 1]} ${n.day.toString().padLeft(2, '0')} ${monthLong[n.month - 1]} ${n.year}, '
        '${hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')} ${n.hour < 12 ? 'AM' : 'PM'}';
    return 'TIME: $time\nPROFILE:\n${profile.isEmpty ? '(not set up yet)' : profile}\n'
        'MEMORY:\n${memories.isEmpty ? '(nothing yet)' : memories}\nOPEN TASKS: ${today.isEmpty ? 'none' : today}.$mtg$note\n'
        'Reply language: ${_replyLanguage(lang, speak)}.';
  }

  Future<void> converse(String text, String lang, bool speak) async {
    setState('thinking');
    final name = ((_s('agent_name', 'Snapy') as String?) ?? 'Snapy').trim();
    final messages = <Msg>[
      {'role': 'system', 'content': core.prompt('system', {'agent_name': name.isEmpty ? 'Snapy' : name})},
      {'role': 'system', 'content': contextText(text, lang, speak)},
      ...history.length > 6 ? history.sublist(history.length - 6) : history,
      {'role': 'user', 'content': text},
    ];
    history.add({'role': 'user', 'content': text});
    final msgId = _newId();
    _answering = text;
    _partial = '';
    final streamer = JsonFieldStreamer('say'), chunker = SentenceChunker();
    var spoken = '', raw = '';
    var lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await for (final chunk in llm.stream(messages, schema: core.actionSchema(), maxTokens: 160, cancel: _cancel)) {
        raw += chunk;
        final piece = streamer.feed(chunk);
        if (piece.isNotEmpty) {
          spoken += piece;
          _partial = spoken;
          if (speak) {
            for (final s in chunker.feed(piece)) {
              say(s, lang);
              setState('speaking');
            }
          }
          if (DateTime.now().difference(lastEmit).inMilliseconds > 150) {
            msg('assistant', spoken, finalMsg: false, id: msgId);
            lastEmit = DateTime.now();
          }
        }
      }
    } catch (e) {
      _answering = null;
      reply("I couldn't reach my AI model ($e).", lang, speak, {'error': true});
      return;
    }
    _answering = null;
    if (_cancel.isSet) return;
    if (speak) {
      for (final s in chunker.flush()) {
        say(s, lang);
      }
    }
    final plan = parseJsonObject(raw);
    if (spoken.isEmpty) spoken = (plan['say'] as String?) ?? '';
    final tool = (plan['tool'] as String?) ?? 'none';
    final args = Map<String, dynamic>.from((plan['args'] as Map?) ?? const {});
    if (speak && spoken.isNotEmpty && raw.isNotEmpty && streamer.feed('').isEmpty && !raw.contains('"say"')) say(spoken, lang);
    msg('assistant', spoken, id: msgId, extra: {'tool': tool != 'none' ? tool : null, 'brain': llm.lastUsed});
    memory.recordTurn('assistant', spoken, lang);
    history.add({'role': 'assistant', 'content': spoken});
    if (tool != 'none' && tool.isNotEmpty) await runTool(tool, args, text, lang, speak);
    _learn(text, spoken);
  }

  Future<void> runTool(String tool, Map<String, dynamic> args, String userText, String lang, bool speak) async {
    emit({'type': 'action_log', 'text': userText, 'result': tool, 'ok': true, 'ts': epochSeconds(now())});
    switch (tool) {
      case 'desktop':
        final cmd = ((args['command'] ?? '') as String).trim();
        if (cmd.isEmpty) return;
        if (core.anyMatch('assistant_risky', cmd)) {
          pending = {'kind': 'action', 'command': cmd};
          reply('Just to confirm — should I $cmd?', lang, speak);
          return;
        }
        final r = await agent.execute(_keepUsersTopic(cmd, userText));
        if (!r.ok && r.action != 'ignored') reply(r.message, lang, speak, {'error': true});
      case 'add_task':
        final title = rules.cleanTitle(((args['title'] as String?)?.isNotEmpty ?? false) ? args['title'] as String : userText);
        final w = (args['when'] as String?)?.isNotEmpty == true ? rules.parseWhen(args['when'] as String, now()).$1 : rules.parseWhen(userText, now()).$1;
        tasks.add(title, w, source: 'assistant');
        _emitTasks();
      case 'add_note':
        emit({'type': 'note_added', 'note': notes.add(((args['text'] as String?)?.isNotEmpty ?? false) ? args['text'] as String : userText)});
      case 'remember':
        final fact = (args['fact'] as String?) ?? '';
        if (fact.isNotEmpty) {
          memory.add(fact, category: 'fact', importance: 4, source: 'assistant');
          emit({'type': 'memory', 'profile': memory.profile, 'memories': memory.memories});
        }
      case 'meeting_notes':
        final action = ((args['action'] as String?) ?? 'start').toLowerCase();
        if (action == 'start' && !meeting.recording) {
          meeting.start();
          emit({'type': 'meeting', ...meeting.state()});
        } else if (action == 'stop' && meeting.recording) {
          unawaited(finishMeeting(lang, speak));
        } else if (action == 'bookmark') {
          meeting.bookmark((args['text'] as String?) ?? '');
        }
      case 'complete_task':
        final x = tasks.find((args['title'] as String?) ?? userText);
        if (x != null) {
          tasks.complete(x['id'] as String);
          _emitTasks();
        }
      case 'find_notes':
        final hits = notes.search((args['query'] as String?) ?? userText, limit: 3);
        reply(hits.isNotEmpty ? hits.map((n) => (((n['title'] as String?) ?? n['text']) as String)).map((s) => s.length > 80 ? s.substring(0, 80) : s).join('; ') : "I couldn't find a note like that.",
            lang, speak);
      case 'forget':
        if (memory.forget((args['fact'] as String?) ?? userText) != null) {
          emit({'type': 'memory', 'profile': memory.profile, 'memories': memory.memories});
        }
      case 'day_summary':
        reply(briefing.wrapUp()['text'] as String, lang, speak);
      case 'screen':
        final act = ((args['action'] as String?) ?? 'read').toLowerCase();
        final q = (args['query'] as String?) ?? (args['title'] as String?) ?? '';
        if (act == 'click' && q.isNotEmpty) {
          emit({'type': 'op', 'op': 'screen_tap', 'args': <dynamic>[], 'kwargs': {'query': q}});
        } else if (act == 'type' && (args['text'] as String?)?.isNotEmpty == true) {
          emit({'type': 'op', 'op': 'type_text', 'args': <dynamic>[], 'kwargs': {'text': args['text']}});
        }
      case 'open_panel':
        emit({'type': 'ui_action', 'action': 'open_drawer', 'tab': (args['panel'] as String?) ?? 'today'});
      case 'tasks':
        emit({'type': 'ui_action', 'action': 'open_drawer', 'tab': 'tasks'});
      case 'activity':
        emit({'type': 'ui_action', 'action': 'open_drawer', 'tab': 'activity'});
      default:
        break; // desktop-only tools (focus, work_context, clipboard, read_page, web_search…) are not on the phone yet
    }
  }

  /// If the AI's play/search topic shares no words with what the user said, use the user's words.
  String _keepUsersTopic(String cmd, String userText) {
    final m = RegExp(r'^(play|search for|search|watch|put on)\s+(.+?)(\s+on\s+(?:youtube|spotify))?$', caseSensitive: false).firstMatch(cmd.trim());
    if (m == null) return cmd;
    final words = RegExp('[a-zऀ-ॿ]{3,}').allMatches(m[2]!.toLowerCase()).map((x) => x[0]!).toSet()
      ..removeAll(const {'some', 'songs', 'song', 'music', 'video', 'videos'});
    final said = userText.toLowerCase();
    if (words.isEmpty || words.any(said.contains)) return cmd;
    final own = rules.playPipeline(userText).q;
    return own != null ? '${m[1]} $own${m[3] ?? ' on youtube'}' : cmd;
  }

  void _noLlmReply(String text, String lang, bool speak) {
    final low = pyStrip(text.toLowerCase().trim(), ' ?!.');
    String m;
    if (RegExp(r'^(hi|hello|hey|namaste|good (morning|afternoon|evening))\b').hasMatch(low)) {
      m = 'Hi! I can keep reminders and notes, call or message people, and open apps. What do you need?';
    } else if (RegExp(r'\b(thank|thanks|shukriya|dhanyavad)\b').hasMatch(low)) {
      m = 'Anytime!';
    } else if (RegExp(r'\bhow are you\b|kaise ho').hasMatch(low)) {
      m = "I'm good, thanks! What can I do for you?";
    } else if (RegExp(r'\bwhat can you do\b|\bhelp\b').hasMatch(low)) {
      emit({'type': 'ui_action', 'action': 'open_drawer', 'tab': 'help'});
      m = 'Try “remind me at 5 to call mom”, “WhatsApp Rahul I\'m on my way” or “open YouTube”.';
    } else if (!explainedNoLlm) {
      explainedNoLlm = true;
      m = "I can't chat about that yet — my AI brain isn't set up. Add an API key in Settings → AI brain, or pair your laptop. "
          'Commands, reminders, notes and phone actions already work.';
    } else {
      m = 'That needs my AI brain (Settings → AI brain).';
    }
    reply(m, lang, speak, {'error': m.contains('AI brain')});
  }

  // ------------------------------------------------------------ memory learning
  void _learn(String userText, String replyText) {
    if (memory.worthExtracting(userText)) _learnQueue.add((userText, replyText));
  }

  void _scheduleLearning() {
    _learnTimer?.cancel();
    if (_learnQueue.isEmpty) return;
    _learnTimer = Timer(learnAfterQuiet, () async {
      if (working) return _scheduleLearning();
      final brain = llm.forPurpose('memory');
      if (!await brain.ready()) {
        _learnQueue.clear();
        return;
      }
      while (_learnQueue.isNotEmpty && !working) {
        final (u, r) = _learnQueue.removeAt(0);
        try {
          final applied = await memory.extractAndConsolidate(u, r, (m, s) => brain.chatJson(m, s, maxTokens: 220));
          if (applied.isNotEmpty) {
            emit({'type': 'memory_learned', 'items': [for (final a in applied) if (a.$2 != null) a.$2!['text']]});
          }
        } catch (_) {}
      }
    });
  }

  void dispose() => _learnTimer?.cancel();
}
