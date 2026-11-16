// Meeting audio + Markdown vault (docs/ANDROID_NEXT_PLAN.md §5).
//
//  - The audio is recorded by Kotlin inside the mic foreground service (WakeWordService,
//    recording mode) to files/snapy/meetings/<id>.m4a; it never leaves the phone unless the
//    user switched on `meeting_audio_upload` AND uses their own Gemini key (BYOK, disclosed):
//    then [geminiAudioSummary] sends the audio inline with the transcript to Gemini.
//  - [meetingMarkdown] renders a meeting note as the vault file
//    files/snapy/vault/meetings/YYYY-MM-DD_<slug>.md.
import 'dart:convert';
import 'dart:io';

/// Gemini accepts up to ~20 MB per request inline; keep the audio under this.
const maxInlineAudioBytes = 14 * 1024 * 1024;

String slugify(String s, {int max = 40}) {
  var out = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9ऀ-ॿ]+'), '-').replaceAll(RegExp(r'-+'), '-');
  out = out.replaceAll(RegExp(r'^-|-$'), '');
  if (out.length > max) out = out.substring(0, max).replaceAll(RegExp(r'-$'), '');
  return out.isEmpty ? 'meeting' : out;
}

String _mmss(int t) => '${(t ~/ 60).toString().padLeft(2, '0')}:${(t % 60).toString().padLeft(2, '0')}';

/// The vault Markdown for a meeting note (title, participants, discussion, decisions, action
/// items with owners, transcript).
String meetingMarkdown(Map<String, dynamic> note) {
  final b = StringBuffer();
  final title = '${note['title'] ?? 'Meeting'}';
  b.writeln('# $title');
  b.writeln();
  final started = '${note['started'] ?? ''}'.replaceFirst('T', ' ');
  final mins = ((note['duration'] as num?) ?? 0) ~/ 60;
  b.writeln('- **When:** ${started.isEmpty ? '—' : started} · $mins min');
  final tx = [for (final s in (note['transcript'] as List?) ?? const []) Map<String, dynamic>.from(s as Map)];
  final people = <String>{
    for (final p in (note['participants'] as List?) ?? const []) '$p',
    for (final s in tx) '${s['who'] ?? ''}',
  }..removeWhere((p) => p.isEmpty);
  b.writeln('- **Participants:** ${people.isEmpty ? '—' : people.join(', ')}');
  b.writeln('- **Summary by:** ${note['ai_summary'] == true ? (note['audio_used'] == true ? 'AI (transcript + audio, your key)' : 'AI (transcript, your key)') : 'on-device rules (no AI)'}');
  if (note['audio'] is String) b.writeln('- **Audio:** ${(note['audio'] as String).split('/').last} (on this phone only)');
  void section(String h, List<dynamic>? items) {
    if (items == null || items.isEmpty) return;
    b.writeln();
    b.writeln('## $h');
    for (final i in items) {
      b.writeln('- $i');
    }
  }

  section('Discussion', note['summary'] as List?);
  section('Key points', note['key_points'] as List?);
  section('Decisions', note['decisions'] as List?);
  final acts = (note['actions'] as List?) ?? const [];
  if (acts.isNotEmpty) {
    b.writeln();
    b.writeln('## Action items');
    for (final a in acts) {
      final m = Map<String, dynamic>.from(a as Map);
      final done = m['status'] == 'accepted' ? 'x' : ' ';
      final due = '${m['due'] ?? ''}'.trim();
      final owner = m['mine'] == true ? 'me' : '${m['owner'] ?? 'unassigned'}';
      b.writeln('- [$done] ${m['task']} — $owner${due.isEmpty ? '' : ' (due $due)'}${m['task_id'] != null ? ' · added to tasks' : ''}');
    }
  }
  if (tx.isNotEmpty) {
    b.writeln();
    b.writeln('## Transcript');
    for (final s in tx) {
      b.writeln('- [${_mmss(((s['t'] as num?) ?? 0).toInt())}] ${s['who']}: ${s['text']}');
    }
  }
  return b.toString();
}

/// Summary JSON (the meeting_summary schema) from Gemini with the audio inline, or null.
/// Throws nothing: any failure returns null and the caller falls back to the transcript.
Future<Map<String, dynamic>?> geminiAudioSummary({
  required String apiKey,
  required String model,
  required File audio,
  required String systemPrompt,
  required String transcript,
  HttpClient Function()? client,
  Duration timeout = const Duration(seconds: 90),
}) async {
  try {
    if (apiKey.isEmpty || model.isEmpty || !audio.existsSync()) return null;
    final len = audio.lengthSync();
    if (len == 0 || len > maxInlineAudioBytes) return null;
    final body = {
      'system_instruction': {
        'parts': [
          {'text': systemPrompt}
        ]
      },
      'contents': [
        {
          'role': 'user',
          'parts': [
            {
              'text': 'Summarise this meeting. The audio is the full recording; the on-device transcript below may be partial or have recognition errors.\n\nTranscript:\n'
                  '${transcript.length > 9000 ? transcript.substring(0, 9000) : transcript}'
            },
            {
              'inline_data': {'mime_type': 'audio/mp4', 'data': base64Encode(audio.readAsBytesSync())}
            },
          ]
        }
      ],
      'generationConfig': {'responseMimeType': 'application/json', 'maxOutputTokens': 1400, 'temperature': 0.2},
    };
    final c = (client ?? HttpClient.new)()..connectionTimeout = const Duration(seconds: 8);
    final req = await c.postUrl(Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent'));
    req.headers.set('content-type', 'application/json');
    req.headers.set('x-goog-api-key', apiKey);
    req.add(utf8.encode(jsonEncode(body)));
    final r = await req.close().timeout(timeout);
    final text = await r.transform(utf8.decoder).join();
    c.close(force: true);
    if (r.statusCode >= 400) return null;
    final parts = (((jsonDecode(text) as Map)['candidates'] as List?)?.first as Map?)?['content']?['parts'] as List?;
    final out = parts?.map((p) => (p as Map)['text'] ?? '').join() ?? '';
    final start = out.indexOf('{'), end = out.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    final v = jsonDecode(out.substring(start, end + 1));
    return v is Map ? Map<String, dynamic>.from(v) : null;
  } catch (_) {
    return null;
  }
}
