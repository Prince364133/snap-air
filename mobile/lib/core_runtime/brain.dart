// The AI brain on the phone: one router over four backends, tried in this order
//   1. Gemini Nano (ML Kit GenAI Prompt API, via Kotlin) — only while Snapy is the foreground app
//   2. a small on-device model                            — interface only (TODO, see OnDeviceBackend)
//   3. the user's own cloud key (Gemini / OpenAI / Anthropic / OpenAI-compatible…), redacted
//   4. the paired laptop over the LAN                      — hook set by lib/sync (PairedBrain)
// settings.ai_provider: auto (the order above) | local (1, 2, 4 only) | cloud (3 first, then the rest).
// Memory learning never goes to the cloud unless settings.cloud_for_memory.
// Python reference: engine/src/brain/cloud.py (requests, SSE, redaction, model fallback).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'core_data.dart';
import 'stores.dart';

typedef Msg = Map<String, String>;

class Cancel {
  bool _set = false;
  bool get isSet => _set;
  void set() => _set = true;
  void clear() => _set = false;
}

abstract class LlmBackend {
  String get name;
  Future<bool> ready();
  Stream<String> stream(List<Msg> messages, {Map<String, dynamic>? schema, int maxTokens = 300, double temperature = 0.4, Cancel? cancel});
  Future<String> chatText(List<Msg> messages, {int maxTokens = 300, double temperature = 0.4});

  Future<Map<String, dynamic>> chatJson(List<Msg> messages, Map<String, dynamic> schema, {int maxTokens = 256, double temperature = 0.2}) async {
    final withHint = [...messages];
    if (withHint.isNotEmpty) {
      withHint[0] = {...withHint[0], 'content': '${withHint[0]['content']}$jsonHint'};
    }
    return parseJsonObject(await chatText(withHint, maxTokens: maxTokens, temperature: temperature));
  }
}

const jsonHint = '\nRespond with a JSON object whose keys appear in this order: "say", "tool", "args". '
    'No text outside the JSON.';

/// json.loads, else the first {...} block, else {} (assistant._parse / cloud.chat_json).
Map<String, dynamic> parseJsonObject(String raw) {
  var text = raw.trim().replaceAll(RegExp(r'^```(?:json)?|```$'), '').trim();
  try {
    final v = jsonDecode(text);
    if (v is Map) return Map<String, dynamic>.from(v);
  } catch (_) {}
  final m = RegExp(r'\{.*\}', dotAll: true).firstMatch(text);
  if (m != null) {
    try {
      final v = jsonDecode(m[0]!);
      if (v is Map) return Map<String, dynamic>.from(v);
    } catch (_) {}
  }
  return {};
}

// ------------------------------------------------------------------ streaming helpers
/// Incrementally extracts one string field ("say") from streamed JSON (llm.JsonFieldStreamer).
class JsonFieldStreamer {
  final String field;
  String _buf = '';
  int? _pos;
  bool done = false;
  JsonFieldStreamer([this.field = 'say']);

  String feed(String chunk) {
    _buf += chunk;
    if (done) return '';
    if (_pos == null) {
      final m = RegExp('"${RegExp.escape(field)}"\\s*:\\s*"').firstMatch(_buf);
      if (m == null) return '';
      _pos = m.end;
    }
    final out = StringBuffer();
    var i = _pos!;
    final s = _buf;
    while (i < s.length) {
      final c = s[i];
      if (c == r'\') {
        if (i + 1 >= s.length) break;
        final nxt = s[i + 1];
        if (nxt == 'u') {
          if (i + 6 > s.length) break;
          final code = int.tryParse(s.substring(i + 2, i + 6), radix: 16);
          if (code != null) out.writeCharCode(code);
          i += 6;
          continue;
        }
        out.write(const {'n': '\n', 't': ' ', '"': '"', r'\': r'\', '/': '/'}[nxt] ?? nxt);
        i += 2;
        continue;
      }
      if (c == '"') {
        done = true;
        i++;
        break;
      }
      out.write(c);
      i++;
    }
    _pos = i;
    return out.toString();
  }
}

/// Removes `<think>…</think>` from a token stream, even when tags are split across chunks.
class ThinkFilter {
  String _buf = '';
  bool _inside = false;

  String feed(String chunk) {
    _buf += chunk;
    final out = StringBuffer();
    while (_buf.isNotEmpty) {
      if (_inside) {
        final end = _buf.indexOf('</think>');
        if (end < 0) {
          _buf = _buf.length > 7 ? _buf.substring(_buf.length - 7) : _buf;
          return out.toString();
        }
        _buf = _buf.substring(end + 8);
        _inside = false;
      } else {
        final start = _buf.indexOf('<think>');
        if (start < 0) {
          var keep = 0;
          for (var n = _buf.length < 6 ? _buf.length : 6; n > 0; n--) {
            if ('<think>'.startsWith(_buf.substring(_buf.length - n))) {
              keep = n;
              break;
            }
          }
          out.write(_buf.substring(0, _buf.length - keep));
          _buf = _buf.substring(_buf.length - keep);
          return out.toString();
        }
        out.write(_buf.substring(0, start));
        _buf = _buf.substring(start + 7);
        _inside = true;
      }
    }
    return out.toString();
  }
}

/// Splits streamed speech into sentences for TTS (voice/tts.SentenceChunker, simplified).
class SentenceChunker {
  String _buf = '';
  static final _end = RegExp(r'[.!?।](?:\s|$)');

  List<String> feed(String piece) {
    _buf += piece;
    final out = <String>[];
    while (true) {
      final m = _end.firstMatch(_buf);
      if (m == null || m.end < 12 && _buf.length < 40) break;
      out.add(_buf.substring(0, m.end).trim());
      _buf = _buf.substring(m.end);
    }
    return out.where((s) => s.isNotEmpty).toList();
  }

  List<String> flush() {
    final s = _buf.trim();
    _buf = '';
    return s.isEmpty ? [] : [s];
  }
}

// ------------------------------------------------------------------ redaction (cloud.py)
final _keyLike = RegExp(r'\b(?:sk-(?:ant-|proj-)?[A-Za-z0-9_-]{16,}|AIza[0-9A-Za-z_-]{30,}|gsk_[A-Za-z0-9]{20,}'
    r'|xai-[A-Za-z0-9]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}'
    r'|AKIA[0-9A-Z]{16}|pplx-[A-Za-z0-9]{20,}|sk-or-[A-Za-z0-9-]{20,}|xox[abpr]-[A-Za-z0-9-]{10,})');
final _longToken = RegExp(r'(?<![A-Za-z0-9_\-])(?=[A-Za-z0-9_\-]*\d)(?=[A-Za-z0-9_\-]*[A-Za-z])[A-Za-z0-9_\-]{32,}');
final _email = RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}');
final _userPath = RegExp(r'((?:\b[A-Z]:)?[\\/]+(?:Users|home|Documents and Settings)[\\/]+)([^\\/:*?"<>|\r\n\s]+)', caseSensitive: false);
final _card = RegExp(r'(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)');
final _phone = RegExp(r'(?<![\w.])\+?\(?\d[\d\s().-]{7,}\d(?![\w.])');
final _date = RegExp(r'\d{4}-\d{2}-\d{2}');
const _skipUser = {'public', 'default', 'all users', '[user]'};

bool _luhn(String digits) {
  var total = 0;
  var alt = false;
  for (final ch in digits.split('').reversed) {
    var d = int.parse(ch);
    if (alt) d = d > 4 ? d * 2 - 9 : d * 2;
    total += d;
    alt = !alt;
  }
  return total % 10 == 0;
}

/// Mask emails, phone and card numbers, API-key-like strings and user names in paths.
String redact(String text) {
  if (text.isEmpty) return text;
  text = text.replaceAll(_keyLike, '[key]');
  text = text.replaceAll(_longToken, '[key]');
  text = text.replaceAll(_email, '[email]');
  text = text.replaceAllMapped(_userPath, (m) => m[1]! + (_skipUser.contains(m[2]!.toLowerCase()) ? m[2]! : '[user]'));
  text = text.replaceAllMapped(_card, (m) {
    final digits = m[0]!.replaceAll(RegExp(r'\D'), '');
    return digits.length >= 13 && digits.length <= 19 && _luhn(digits) ? '[card]' : m[0]!;
  });
  text = text.replaceAllMapped(_phone, (m) {
    final s = m[0]!;
    if (_date.hasMatch(s)) return s;
    final n = s.replaceAll(RegExp(r'\D'), '').length;
    return n >= 10 && n <= 15 ? '[phone]' : s;
  });
  return text;
}

List<Msg> redactMessages(List<Msg> messages, {bool enabled = true}) =>
    enabled ? [for (final m in messages) {...m, 'content': redact(m['content'] ?? '')}] : messages;

// ------------------------------------------------------------------ platform hooks
/// API keys live in the Android Keystore (Kotlin KeyCipher); the runtime asks for them per call.
abstract class SecretVault {
  Future<String> getKey(String name);
  Future<void> setKey(String name, String value);
}

class MemoryVault implements SecretVault {
  final Map<String, String> keys = {};
  @override
  Future<String> getKey(String name) async => keys[name] ?? '';
  @override
  Future<void> setKey(String name, String value) async => value.isEmpty ? keys.remove(name) : keys[name] = value.trim();
}

/// Gemini Nano through Kotlin (ML Kit GenAI Prompt API). status(): available | downloadable |
/// downloading | unavailable | background (Snapy is not the foreground app) | error.
abstract class NanoBridge {
  Future<String> status();
  Stream<String> generate(String prompt);
}

/// The paired laptop answers over the LAN (implemented by lib/sync; null until paired).
abstract class PairedBrain {
  Future<bool> available();
  Stream<String> stream(List<Msg> messages, {Map<String, dynamic>? schema, int maxTokens = 300});
}

// ------------------------------------------------------------------ backends
class NanoBackend extends LlmBackend {
  final NanoBridge? bridge;
  NanoBackend(this.bridge);

  @override
  String get name => 'nano';

  @override
  Future<bool> ready() async => bridge != null && await bridge!.status() == 'available';

  /// Nano takes one prompt: system text first, then the recent turns.
  static String flatten(List<Msg> messages, {bool json = false}) {
    final sys = messages.where((m) => m['role'] == 'system').map((m) => m['content']).join('\n\n');
    final turns = messages.where((m) => m['role'] != 'system').map((m) => '${m['role'] == 'assistant' ? 'Assistant' : 'User'}: ${m['content']}');
    return '$sys${json ? jsonHint : ''}\n\n${turns.join('\n')}\nAssistant:';
  }

  @override
  Stream<String> stream(List<Msg> messages, {Map<String, dynamic>? schema, int maxTokens = 300, double temperature = 0.4, Cancel? cancel}) async* {
    final think = ThinkFilter();
    await for (final chunk in bridge!.generate(flatten(messages, json: schema != null))) {
      if (cancel?.isSet ?? false) break;
      final out = think.feed(chunk);
      if (out.isNotEmpty) yield out;
    }
  }

  @override
  Future<String> chatText(List<Msg> messages, {int maxTokens = 300, double temperature = 0.4}) async =>
      (await stream(messages, maxTokens: maxTokens).toList()).join().trim();
}

/// A compact on-device model for phones without Gemini Nano.
/// TODO: no runtime fits the 40 MB APK budget today (llama.cpp/MediaPipe LLM add 5–15 MB of
/// native code per ABI, plus a 0.5–1.5 GB model downloaded on demand). Plug one in here:
/// ready() = model downloaded + loaded; stream() = token stream.
class OnDeviceBackend extends LlmBackend {
  @override
  String get name => 'on_device';
  @override
  Future<bool> ready() async => false;
  @override
  Stream<String> stream(List<Msg> messages, {Map<String, dynamic>? schema, int maxTokens = 300, double temperature = 0.4, Cancel? cancel}) =>
      Stream.error(StateError('no on-device model installed'));
  @override
  Future<String> chatText(List<Msg> messages, {int maxTokens = 300, double temperature = 0.4}) =>
      Future.error(StateError('no on-device model installed'));
}

class PairedBackend extends LlmBackend {
  PairedBrain? Function() hook;
  PairedBackend(this.hook);
  @override
  String get name => 'laptop';
  @override
  Future<bool> ready() async {
    final h = hook();
    return h != null && await h.available();
  }

  @override
  Stream<String> stream(List<Msg> messages, {Map<String, dynamic>? schema, int maxTokens = 300, double temperature = 0.4, Cancel? cancel}) async* {
    await for (final c in hook()!.stream(messages, schema: schema, maxTokens: maxTokens)) {
      if (cancel?.isSet ?? false) break;
      yield c;
    }
  }

  @override
  Future<String> chatText(List<Msg> messages, {int maxTokens = 300, double temperature = 0.4}) async =>
      (await stream(messages, maxTokens: maxTokens).toList()).join().trim();
}

final _keyBad = RegExp(r'api[ _-]?key.{0,30}(not valid|invalid|incorrect)|(invalid|incorrect).{0,20}api[ _-]?key', caseSensitive: false);
final _modelGone = RegExp(
    r'not[ _]found|does not exist|decommission|deprecat|retired|no longer|unknown model|invalid model|model.{0,40}(not supported|unsupported|not available)',
    caseSensitive: false);

class CloudError implements Exception {
  final String message;
  CloudError(this.message);
  @override
  String toString() => message;
}

/// Bring-your-own-key cloud models (core/rules/cloud.json `cloud.providers`).
class CloudBackend extends LlmBackend {
  final CoreData core;
  final Settings settings;
  final SecretVault vault;
  final HttpClient Function() httpClient;
  String? lastError;
  (String, String)? _rejected;
  final Map<String, int> _modelIdx = {};
  (DateTime, bool) _online = (DateTime.fromMillisecondsSinceEpoch(0), false);

  CloudBackend(this.core, this.settings, this.vault, {HttpClient Function()? client}) : httpClient = client ?? HttpClient.new;

  @override
  String get name => 'cloud';

  Map<String, dynamic> get providers => Map<String, dynamic>.from((core.config('cloud.providers') as Map?) ?? const {});

  String _s(String k, [String d = '']) {
    final v = settings.get(k);
    return (v == null || v == '') ? d : '$v';
  }

  String get provider => _s('cloud_provider', 'gemini');
  Map<String, dynamic> get _info => Map<String, dynamic>.from((providers[provider] as Map?) ?? const {});

  List<Map<String, dynamic>> _candidates() {
    if (_info['custom'] == true) {
      final custom = _s('cloud_model');
      return custom.isEmpty ? [] : [{'id': custom}];
    }
    return [for (final m in (_info['models'] as List?) ?? const []) m is Map ? Map<String, dynamic>.from(m) : {'id': '$m'}];
  }

  Map<String, dynamic> _spec() {
    final c = _candidates();
    if (c.isEmpty) return {'id': ''};
    final i = _modelIdx[provider] ?? 0;
    return c[i < c.length ? i : c.length - 1];
  }

  bool _advanceModel() {
    final c = _candidates(), i = _modelIdx[provider] ?? 0;
    if (i + 1 >= c.length) return false;
    _modelIdx[provider] = i + 1;
    return true;
  }

  String get model => _spec()['id'] as String;

  String get baseUrl {
    final base = (_info['base_url'] as String?) ?? '';
    final b = _info['custom'] == true ? _s('cloud_base_url', base) : base;
    return b.replaceAll(RegExp(r'/+$'), '');
  }

  Future<String> key() => vault.getKey('cloud_$provider');

  Future<bool> hasKey() async => (await key()).isNotEmpty && model.isNotEmpty;

  Future<bool> configured() => hasKey();

  Future<bool> keyRejected() async => _rejected != null && _rejected == (provider, await key());

  Future<bool> online() async {
    if (DateTime.now().difference(_online.$1).inSeconds < 60) return _online.$2;
    var ok = false;
    final url = (core.config('web.connectivity_check') as String?) ?? 'https://www.google.com';
    for (final u in [url, 'https://1.1.1.1']) {
      try {
        final c = httpClient()..connectionTimeout = const Duration(seconds: 2);
        final r = await (await c.headUrl(Uri.parse(u))).close().timeout(const Duration(seconds: 3));
        await r.drain<void>();
        c.close(force: true);
        ok = true;
        break;
      } catch (_) {}
    }
    _online = (DateTime.now(), ok);
    return ok;
  }

  @override
  Future<bool> ready() async => await configured() && !await keyRejected() && await online();

  // ------------------------------------------------------------ requests
  (Map<String, dynamic>, int, double?) _gen(int maxTokens, double temperature) {
    final spec = _spec();
    final minT = ((spec['min_max_tokens'] as num?) ?? 0).toInt();
    final n = maxTokens > minT ? maxTokens : minT;
    final temp = spec['sampling'] == false ? null : temperature;
    return (spec, n, temp);
  }

  /// (url, headers, body) for this provider.
  Future<(Uri, Map<String, String>, Map<String, dynamic>)> buildRequest(List<Msg> messages,
      {required bool jsonMode, int maxTokens = 300, double temperature = 0.4, required bool stream}) async {
    final (spec, n, temp) = _gen(maxTokens, temperature);
    final k = await key();
    final extra = Map<String, dynamic>.from((spec['extra'] as Map?) ?? const {});
    if (provider == 'gemini') {
      final system = messages.where((m) => m['role'] == 'system').map((m) => m['content']).join('\n\n');
      final contents = [
        for (final m in messages.where((m) => m['role'] != 'system'))
          {'role': m['role'] == 'assistant' ? 'model' : 'user', 'parts': [{'text': m['content']}]},
      ];
      final gen = <String, dynamic>{'maxOutputTokens': n, 'temperature': ?temp, if (jsonMode) 'responseMimeType': 'application/json', ...extra};
      final body = <String, dynamic>{'contents': contents, 'generationConfig': gen, if (system.isNotEmpty) 'systemInstruction': {'parts': [{'text': system}]}};
      final verb = stream ? 'streamGenerateContent?alt=sse' : 'generateContent';
      return (Uri.parse('$baseUrl/models/${spec['id']}:$verb'), {'x-goog-api-key': k, 'Content-Type': 'application/json'}, body);
    }
    if (provider == 'anthropic') {
      final system = messages.where((m) => m['role'] == 'system').map((m) => m['content']).join('\n\n');
      var chat = [
        for (final m in messages.where((m) => m['role'] != 'system'))
          {'role': m['role'] == 'assistant' ? 'assistant' : 'user', 'content': m['content']},
      ];
      if (chat.isEmpty) chat = [{'role': 'user', 'content': 'Hello'}];
      final body = <String, dynamic>{'model': spec['id'], 'max_tokens': n, 'messages': chat, 'stream': stream, 'temperature': ?temp, if (system.isNotEmpty) 'system': system, ...extra};
      return (Uri.parse('$baseUrl/messages'), {'x-api-key': k, 'anthropic-version': '2023-06-01', 'content-type': 'application/json'}, body);
    }
    final body = <String, dynamic>{
      'model': spec['id'],
      'messages': messages,
      'stream': stream,
      ((spec['token_param'] as String?) ?? 'max_tokens'): n,
      'temperature': ?temp,
      if (jsonMode && _info['json_mode'] == true) 'response_format': {'type': 'json_object'},
      ...extra,
    };
    final headers = {
      'Authorization': 'Bearer $k',
      'Content-Type': 'application/json',
      for (final e in ((_info['headers'] as Map?) ?? const {}).entries) e.key as String: '${e.value}',
    };
    return (Uri.parse('$baseUrl/chat/completions'), headers, body);
  }

  static String errorDetail(String body) {
    try {
      dynamic d = jsonDecode(body);
      if (d is List && d.isNotEmpty) d = d.first;
      if (d is! Map) return '$d'.length > 200 ? '$d'.substring(0, 200) : '$d';
      final err = d['error'];
      if (err is Map) return (err['message'] as String?) ?? '$err';
      final detail = err ?? d['message'] ?? d['detail'];
      final s = detail is String ? detail : '$d';
      return s.length > 200 ? s.substring(0, 200) : s;
    } catch (_) {
      return body.length > 200 ? body.substring(0, 200) : body;
    }
  }

  Future<HttpClientResponse> _request(List<Msg> messages, {required bool jsonMode, int maxTokens = 300, double temperature = 0.4, required bool stream}) async {
    var msgs = redactMessages(messages, enabled: settings.get('cloud_redact') != false);
    if (jsonMode && msgs.isNotEmpty) {
      msgs = [...msgs];
      msgs[0] = {...msgs[0], 'content': '${msgs[0]['content']}$jsonHint'};
    }
    while (true) {
      final (uri, headers, body) = await buildRequest(msgs, jsonMode: jsonMode, maxTokens: maxTokens, temperature: temperature, stream: stream);
      final client = httpClient()..connectionTimeout = const Duration(seconds: 6);
      final req = await client.postUrl(uri);
      headers.forEach(req.headers.set);
      req.add(utf8.encode(jsonEncode(body)));
      final r = await req.close().timeout(const Duration(seconds: 120));
      if (r.statusCode < 400) {
        _rejected = null;
        return r;
      }
      final detail = errorDetail(await r.transform(utf8.decoder).join());
      client.close(force: true);
      if ((r.statusCode == 400 || r.statusCode == 404) && _modelGone.hasMatch(detail) && _advanceModel()) continue;
      lastError = '${_info['label'] ?? provider}: $detail';
      if (r.statusCode == 401 || r.statusCode == 403 || (r.statusCode == 400 && _keyBad.hasMatch(detail))) {
        _rejected = (provider, await key());
      }
      throw CloudError(lastError!);
    }
  }

  /// Text pieces of one SSE `data:` payload for [provider].
  static Iterable<String> sseTexts(String provider, Map<String, dynamic> d) sync* {
    if (provider == 'gemini') {
      for (final c in ((d['candidates'] as List?) ?? const []).take(1)) {
        for (final p in (((c as Map)['content'] as Map?)?['parts'] as List?) ?? const []) {
          final t = (p as Map)['text'];
          if (t is String && t.isNotEmpty) yield t;
        }
      }
    } else if (provider == 'anthropic') {
      if (d['type'] == 'error') throw CloudError('Anthropic Claude: ${(d['error'] as Map?)?['message'] ?? 'stream error'}');
      final delta = (d['delta'] as Map?) ?? const {};
      if (d['type'] == 'content_block_delta' && delta['type'] == 'text_delta' && (delta['text'] as String?)?.isNotEmpty == true) {
        yield delta['text'] as String;
      }
    } else {
      for (final c in ((d['choices'] as List?) ?? const []).take(1)) {
        final t = ((c as Map)['delta'] as Map?)?['content'];
        if (t is String && t.isNotEmpty) yield t;
      }
    }
  }

  static String fullText(String provider, Map<String, dynamic> d) {
    if (provider == 'gemini') {
      final parts = ((((d['candidates'] as List)[0] as Map)['content'] as Map)['parts'] as List);
      return parts.map((p) => ((p as Map)['text'] as String?) ?? '').join();
    }
    if (provider == 'anthropic') {
      return ((d['content'] as List?) ?? const []).where((c) => (c as Map)['type'] == 'text').map((c) => (c as Map)['text']).join();
    }
    return ((((d['choices'] as List)[0] as Map)['message'] as Map)['content'] as String?) ?? '';
  }

  @override
  Stream<String> stream(List<Msg> messages, {Map<String, dynamic>? schema, int maxTokens = 300, double temperature = 0.4, Cancel? cancel}) async* {
    final r = await _request(messages, jsonMode: schema != null, maxTokens: maxTokens, temperature: temperature, stream: true);
    final think = ThinkFilter();
    final p = provider;
    await for (final line in r.transform(utf8.decoder).transform(const LineSplitter())) {
      if (cancel?.isSet ?? false) break;
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data == '[DONE]') break;
      Map<String, dynamic> d;
      try {
        d = Map<String, dynamic>.from(jsonDecode(data) as Map);
      } catch (_) {
        continue;
      }
      for (final t in sseTexts(p, d)) {
        final out = think.feed(t);
        if (out.isNotEmpty) yield out;
      }
    }
  }

  @override
  Future<String> chatText(List<Msg> messages, {int maxTokens = 300, double temperature = 0.4}) async {
    final r = await _request(messages, jsonMode: false, maxTokens: maxTokens, temperature: temperature, stream: false);
    final d = Map<String, dynamic>.from(jsonDecode(await r.transform(utf8.decoder).join()) as Map);
    return fullText(provider, d).replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '').trim();
  }

  @override
  Future<Map<String, dynamic>> chatJson(List<Msg> messages, Map<String, dynamic> schema, {int maxTokens = 256, double temperature = 0.2}) async {
    final r = await _request(messages, jsonMode: true, maxTokens: maxTokens, temperature: temperature, stream: false);
    final d = Map<String, dynamic>.from(jsonDecode(await r.transform(utf8.decoder).join()) as Map);
    return parseJsonObject(fullText(provider, d).replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), ''));
  }

  /// The key check: "Reply with exactly: OK" (no user data).
  Future<String> test() => chatText([
        {'role': 'system', 'content': 'Reply with exactly: OK'},
        {'role': 'user', 'content': 'ping'},
      ], maxTokens: 5, temperature: 0);
}

// ------------------------------------------------------------------ router
class BrainRouter {
  final Settings settings;
  final NanoBackend nano;
  final OnDeviceBackend onDevice;
  final CloudBackend cloud;
  final PairedBackend laptop;
  final String purpose;
  String? lastUsed;

  BrainRouter(this.settings, this.nano, this.onDevice, this.cloud, this.laptop, {this.purpose = 'chat'});

  BrainRouter forPurpose(String p) => BrainRouter(settings, nano, onDevice, cloud, laptop, purpose: p);

  bool get _cloudAllowed => purpose != 'memory' || settings.get('cloud_for_memory') == true;

  /// Backends in the order to try them (settings.ai_provider + purpose).
  List<LlmBackend> order() {
    final mode = (settings.get('ai_provider') as String?) ?? 'auto';
    final local = <LlmBackend>[nano, onDevice, if (settings.get('lan_brain') != false) laptop];
    if (mode == 'local' || !_cloudAllowed) return local;
    if (mode == 'cloud') return [cloud, ...local];
    return [nano, onDevice, cloud, if (settings.get('lan_brain') != false) laptop];
  }

  Future<List<LlmBackend>> readyBackends() async {
    final out = <LlmBackend>[];
    for (final b in order()) {
      try {
        if (await b.ready()) out.add(b);
      } catch (_) {}
    }
    return out;
  }

  Future<bool> ready() async => (await readyBackends()).isNotEmpty;

  /// Streams from the first ready backend; on an error before any output, the next one.
  Stream<String> stream(List<Msg> messages, {Map<String, dynamic>? schema, int maxTokens = 300, Cancel? cancel}) async* {
    Object? lastErr;
    for (final b in await readyBackends()) {
      var produced = false;
      try {
        await for (final c in b.stream(messages, schema: schema, maxTokens: maxTokens, cancel: cancel)) {
          produced = true;
          lastUsed = b.name;
          yield c;
        }
        return;
      } catch (e) {
        lastErr = e;
        if (produced) rethrow;
      }
    }
    throw lastErr ?? StateError('no AI brain available');
  }

  Future<T> _first<T>(Future<T> Function(LlmBackend b) run) async {
    Object? lastErr;
    for (final b in await readyBackends()) {
      try {
        final r = await run(b);
        lastUsed = b.name;
        return r;
      } catch (e) {
        lastErr = e;
      }
    }
    throw lastErr ?? StateError('no AI brain available');
  }

  Future<String> chatText(List<Msg> messages, {int maxTokens = 300}) => _first((b) => b.chatText(messages, maxTokens: maxTokens));

  Future<Map<String, dynamic>> chatJson(List<Msg> messages, Map<String, dynamic> schema, {int maxTokens = 256}) =>
      _first((b) => b.chatJson(messages, schema, maxTokens: maxTokens));
}
