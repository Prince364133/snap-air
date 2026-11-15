import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// App strings, loaded from `assets/i18n/<lang>.json` (copied from core/i18n by
/// tool/sync_core.dart). Missing keys fall back to English, then to the key itself.
/// Nested JSON objects are flattened to dotted keys, so both
/// {"nudge": {"bedtime": "…"}} and {"nudge.bedtime": "…"} work.
///
/// The Kotlin overlay reads the same files from the APK (Strings.kt), so the chip, the cards
/// and the Flutter screens always say the same thing.
///
/// Flutter-only screen strings live in an overlay, `assets/i18n/<lang>.ui.json`, merged on top
/// (sync_core.dart only rewrites `<lang>.json`, so the overlay survives a core sync). Once a key
/// is in core/i18n too, the overlay copy is simply redundant.
class I18n {
  static const supported = ['en', 'hi', 'ta', 'te', 'mr', 'bn'];

  final String lang;
  final Map<String, String> _s;
  final Map<String, String> _en;
  const I18n(this.lang, this._s, this._en);

  static const empty = I18n('en', {}, {});

  /// The strings in use (set by main() before runApp, or by tests).
  static final ValueNotifier<I18n> notifier = ValueNotifier(empty);
  static I18n get current => notifier.value;

  String t(String key, [Map<String, String> params = const {}]) {
    var v = _s[key] ?? _en[key] ?? key;
    params.forEach((k, p) => v = v.replaceAll('{$k}', p));
    return v;
  }

  bool has(String key) => _s.containsKey(key) || _en.containsKey(key);

  static Map<String, String> flatten(dynamic json, [String prefix = '']) {
    final out = <String, String>{};
    if (json is Map) {
      json.forEach((k, v) {
        final key = prefix.isEmpty ? '$k' : '$prefix.$k';
        if (k.toString().startsWith('_')) return;               // "_comment"
        if (v is Map) {
          out.addAll(flatten(v, key));
        } else if (v is List) {
          out[key] = v.join('\n');
        } else if (v != null) {
          out[key] = v.toString();
        }
      });
    }
    return out;
  }

  static I18n fromJson(String lang, String json, {String? enJson}) {
    final s = flatten(jsonDecode(json));
    return I18n(lang, s, enJson == null ? s : flatten(jsonDecode(enJson)));
  }

  /// 'auto' -> the phone's language when we have it, else English.
  static String resolve(String pref, String deviceLang) {
    if (pref != 'auto' && supported.contains(pref)) return pref;
    return supported.contains(deviceLang) ? deviceLang : 'en';
  }

  static Future<I18n> load(String lang, {AssetBundle? bundle}) async {
    final b = bundle ?? rootBundle;
    Map<String, String> layer(String? core, String? ui) {
      final out = <String, String>{};
      for (final j in [core, ui]) {
        if (j == null) continue;
        try {
          out.addAll(flatten(jsonDecode(j)));
        } catch (_) {}
      }
      return out;
    }

    final en = layer(await _read(b, 'en'), await _read(b, 'en.ui'));
    final mine = lang == 'en' ? en : layer(await _read(b, lang), await _read(b, '$lang.ui'));
    return I18n(mine.isEmpty ? 'en' : lang, mine.isEmpty ? en : mine, en);
  }

  /// Both layers of one language from JSON text (tests and tools).
  static I18n fromLayers(String lang, String coreJson, [String? uiJson]) {
    final s = {...flatten(jsonDecode(coreJson)), if (uiJson != null) ...flatten(jsonDecode(uiJson))};
    return I18n(lang, s, s);
  }

  static Future<String?> _read(AssetBundle b, String lang) async {
    try {
      return await b.loadString('assets/i18n/$lang.json', cache: false);
    } catch (_) {
      return null;                 // not translated yet: English is used
    }
  }

  static Future<void> use(String lang) async => notifier.value = await load(lang);
}

/// Short form used by every widget: tr('nudge.bedtime').
String tr(String key, [Map<String, String> params = const {}]) => I18n.current.t(key, params);
