import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/snapy_core.dart';
import '../core/theme.dart';
import 'emoji_burst.dart';

class _Msg {
  final String id;
  String text;
  final bool mine;
  bool ok;
  bool done;
  _Msg(this.id, this.text, {this.mine = false, this.ok = true, this.done = true});
}

/// Chat with Snapy — on the home screen and in the bottom sheet over other apps.
/// Replies stream in from the shared brain as events (same Assistant as Windows).
class AssistantPanel extends StatefulWidget {
  final ScrollController? scrollController;
  final VoidCallback? onAction;          // e.g. close the sheet after "open WhatsApp"
  const AssistantPanel({super.key, this.scrollController, this.onAction});

  @override
  State<AssistantPanel> createState() => _AssistantPanelState();
}

class _AssistantPanelState extends State<AssistantPanel> {
  final _input = TextEditingController();
  final _msgs = <_Msg>[
    _Msg('hello', 'Hi! Ask me anything, or try “remind me at 5 to call mom”, “remember that I prefer Slack”, '
        '“YouTube kholo” or “play Arijit songs, the 4th video”.')
  ];
  String _state = 'idle';
  String _voice = 'idle';          // listening / partial / thinking / idle / error
  String _heard = '';
  double _level = 0;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _sub = SnapyCore.events.listen(_onEvent, onError: (_) {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onEvent(Map<String, dynamic> e) {
    if (!mounted) return;
    switch (e['type']) {
      case 'chat_message':
        final id = (e['id'] ?? '').toString();
        final mine = e['role'] == 'user';
        if (mine) return;                                  // we already show what the user typed
        final i = _msgs.indexWhere((m) => m.id == id);
        setState(() {
          if (i >= 0) {
            _msgs[i]
              ..text = (e['text'] ?? '').toString()
              ..done = e['final'] != false
              ..ok = e['error'] != true;
          } else {
            _msgs.add(_Msg(id, (e['text'] ?? '').toString(), ok: e['error'] != true, done: e['final'] != false));
          }
        });
      case 'voice':
        final st = (e['state'] ?? 'idle').toString();
        if (st == 'level') {
          setState(() => _level = ((e['level'] ?? 0) as num).toDouble());
          return;
        }
        setState(() {
          _voice = st;
          _heard = (e['text'] ?? '').toString();
          if (st == 'thinking' && _heard.isNotEmpty) {
            _msgs.add(_Msg('v${DateTime.now().microsecondsSinceEpoch}', _heard, mine: true));
            _heard = '';
          }
        });
        if (st == 'error' && e['error'] != null) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(e['error'].toString())));
        }
      case 'assistant_state':
        setState(() => _state = (e['state'] ?? 'idle').toString());
      case 'op':
        widget.onAction?.call();                           // a phone action ran: get out of the way
      case 'ui_action':
        if (e['action'] == 'emoji') EmojiBurst.show(context, List<String>.from(e['emojis'] as List? ?? const []));
        if (e['action'] == 'quit') SystemNavigator.pop();
      case 'toast':
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text((e['text'] ?? '').toString())));
    }
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty) return;
    _input.clear();
    setState(() => _msgs.add(_Msg('u${DateTime.now().microsecondsSinceEpoch}', text, mine: true)));
    try {
      await SnapyCore.send(text);
    } catch (_) {
      setState(() => _msgs.add(_Msg('err', 'Snapy is still starting — try again in a second.', ok: false)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final thinking = _state == 'thinking';
    final listening = _voice == 'listening' || _voice == 'partial';
    return Column(children: [
      Expanded(
        child: ListView.builder(
          controller: widget.scrollController,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          itemCount: _msgs.length + (thinking ? 1 : 0),
          itemBuilder: (_, i) => i < _msgs.length ? _Bubble(_msgs[i]) : const _Typing(),
        ),
      ),
      if (listening)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
          child: Row(children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 10 + 14 * _level,
              height: 10 + 14 * _level,
              decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(_heard.isEmpty ? 'Listening…' : _heard,
                  style: TextStyle(fontSize: 17, color: _heard.isEmpty ? c.text2 : c.text)),
            ),
          ]),
        ),
      SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: ['what are my tasks?', 'remind me at 5 to call mom', 'YouTube kholo', 'what do you know about me?', 'go back']
              .map((t) => Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      label: Text(t),
                      onPressed: () => _send(t),
                      side: BorderSide(color: c.hairStrong),
                      backgroundColor: c.card,
                      shape: const StadiumBorder(),
                    ),
                  ))
              .toList(),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _input,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: 'Ask Snapy anything…',
                filled: true,
                fillColor: c.card,
                contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide(color: c.hair)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide(color: c.hair)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: listening ? 'Stop listening' : 'Talk to Snapy',
            onPressed: () async {
              if (listening) {
                await SnapyCore.stopListening();
              } else if (!await SnapyCore.startListening()) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Allow the microphone, then tap the mic again.')));
              }
            },
            style: IconButton.styleFrom(backgroundColor: listening ? c.accent : c.fill),
            icon: Icon(listening ? Icons.graphic_eq_rounded : Icons.mic_none_rounded,
                color: listening ? Colors.white : c.text),
          ),
          const SizedBox(width: 4),
          thinking
              ? IconButton.filledTonal(onPressed: SnapyCore.interrupt, icon: const Icon(Icons.stop_rounded), tooltip: 'Stop')
              : IconButton.filled(onPressed: _send, icon: const Icon(Icons.arrow_upward_rounded), tooltip: 'Send'),
        ]),
      ),
    ]);
  }
}

class _Typing extends StatelessWidget {
  const _Typing();
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Text('Snapy is thinking…', style: Theme.of(context).textTheme.bodySmall),
        ),
      );
}

class _Bubble extends StatelessWidget {
  final _Msg m;
  const _Bubble(this.m);

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    return Align(
      alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: m.mine ? c.accent : (m.ok ? c.fill : c.red.withValues(alpha: 0.12)),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(m.text.isEmpty ? '…' : m.text,
            style: TextStyle(color: m.mine ? Colors.white : c.text, fontSize: 15, height: 1.35)),
      ),
    );
  }
}
