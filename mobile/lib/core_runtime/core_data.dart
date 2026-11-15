// The shared core/ folder for the Dart runtime (spec: core/README.md).
//
// Everything is read once, asynchronously, from a [CoreSource] (Flutter assets in the app,
// the repo's ../core folder in tests); after [CoreData.load] every lookup is synchronous.
// Mirrors engine/src/core_loader.py: config tree (one source per leaf), regex dialect with
// macros, intent domains by type, prompts, tools, schemas and i18n.
import 'dart:convert';
import 'dart:io';

import 'py.dart';

class CoreError implements Exception {
  final String message;
  CoreError(this.message);
  @override
  String toString() => 'CoreError: $message';
}

/// Where core/ files come from. Paths are relative to core/ with '/' separators.
abstract class CoreSource {
  Future<String?> read(String rel);

  /// Files (relative to core/) directly inside [dir].
  Future<List<String>> list(String dir);
}

/// The repo's core/ folder (tests, desktop tools).
class DirCoreSource implements CoreSource {
  final String root;
  DirCoreSource(this.root);

  @override
  Future<String?> read(String rel) async {
    final f = File('$root/$rel');
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  @override
  Future<List<String>> list(String dir) async {
    final d = Directory('$root/$dir');
    if (!d.existsSync()) return [];
    final out = d.listSync().whereType<File>().map((f) => '$dir/${f.uri.pathSegments.last}').toList()..sort();
    return out;
  }
}

/// Flutter assets copied by tool/sync_core.dart into assets/core/ (with an index file,
/// because an asset bundle cannot list folders). [loader] is rootBundle.loadString.
class AssetCoreSource implements CoreSource {
  final Future<String> Function(String key) loader;
  final String prefix;
  List<String>? _index;
  AssetCoreSource(this.loader, {this.prefix = 'assets/core/'});

  @override
  Future<String?> read(String rel) async {
    try {
      return await loader('$prefix$rel');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<String>> list(String dir) async {
    _index ??= List<String>.from(jsonDecode((await read('_files.json')) ?? '[]') as List);
    return _index!.where((p) => p.startsWith('$dir/') && !p.substring(dir.length + 1).contains('/')).toList();
  }
}

/// One entry of an intent domain, compiled.
class IntentEntry {
  final Map<String, dynamic> raw;
  final String file;
  final RegExp? rx;
  final String? source; // fragment domains: the expanded source
  IntentEntry(this.raw, this.file, {this.rx, this.source});

  String? get id => raw['id'] as String?;
  String? get intent => raw['intent'] as String?;
  String get replace => (raw['replace'] as String?) ?? '';
  dynamic operator [](String k) => raw[k];
}

class CoreData {
  static const supportedMajor = 1;

  final String version;
  final Map<String, dynamic> manifest;
  final Map<String, dynamic> configTree;
  final Map<String, dynamic> intentIndex;
  final List<(String, Map<String, dynamic>)> intentFiles;
  final Map<String, String> prompts; // name (without .md) -> text
  final Map<String, dynamic> promptJson; // name (without .json) -> json
  final Map<String, dynamic> tools;
  final Map<String, dynamic> schemas; // name -> schema
  final Map<String, Map<String, String>> _i18n; // lang -> merged strings (with en fallback)
  final Map<String, String> macros;
  final Map<String, Object> _domains = {};

  CoreData._(this.version, this.manifest, this.configTree, this.intentIndex, this.intentFiles, this.prompts,
      this.promptJson, this.tools, this.schemas, this._i18n, this.macros);

  // ------------------------------------------------------------------ loading
  static Future<CoreData> load(CoreSource src) async {
    Future<String> text(String rel) async {
      final t = await src.read(rel);
      if (t == null) throw CoreError('core file missing: $rel');
      return t.replaceAll('\r\n', '\n');
    }

    Future<Map<String, dynamic>> json(String rel) async => Map<String, dynamic>.from(jsonDecode(await text(rel)) as Map);

    final version = (await text('VERSION')).trim();
    final major = int.tryParse(version.split('.').first) ?? -1;
    if (major != supportedMajor) throw CoreError('core major version $version is not supported (need $supportedMajor.x)');
    final manifest = await json('manifest.json');

    // config tree
    final tree = <String, dynamic>{};
    final owner = <String, String>{};
    for (final rel in List<String>.from(manifest['config'] as List)) {
      final frag = await json(rel)..remove('_meta');
      _merge(tree, frag, '', owner, rel);
    }

    // intents
    final indexRel = manifest['intents'] as String;
    final idx = await json(indexRel);
    final intentDir = indexRel.contains('/') ? indexRel.substring(0, indexRel.lastIndexOf('/')) : '';
    final files = <(String, Map<String, dynamic>)>[];
    for (final f in List<String>.from(idx['files'] as List)) {
      files.add((f, await json(intentDir.isEmpty ? f : '$intentDir/$f')));
    }
    final macros = <String, String>{};
    for (final (fname, data) in files) {
      for (final e in ((data['macros'] as Map?) ?? const {}).entries) {
        if (macros.containsKey(e.key)) throw CoreError('macro ${e.key} defined twice ($fname)');
        macros[e.key as String] = e.value as String;
      }
    }
    final ordinals = (_walk(tree, 'ordinals') as Map?) ?? const {};
    final ordKeys = stableSorted(ordinals.keys.map((k) => RegExp.escape(k as String)).toList(), (a, b) => b.length - a.length);
    macros['ORDINALS'] = ordKeys.join('|');

    // prompts
    final promptsDir = manifest['prompts'] as String;
    final prompts = <String, String>{};
    final promptJson = <String, dynamic>{};
    for (final rel in await src.list(promptsDir)) {
      final name = rel.substring(promptsDir.length + 1);
      if (name.endsWith('.md')) {
        prompts[name.substring(0, name.length - 3)] = pyRstrip(await text(rel), '\n');
      } else if (name.endsWith('.json')) {
        promptJson[name.substring(0, name.length - 5)] = jsonDecode(await text(rel));
      }
    }
    final tools = await json(manifest['tools'] as String);
    final schemasDir = manifest['schemas'] as String;
    final schemas = <String, dynamic>{};
    for (final rel in await src.list(schemasDir)) {
      final name = rel.substring(schemasDir.length + 1);
      if (name.endsWith('.schema.json')) schemas[name.substring(0, name.length - 12)] = jsonDecode(await text(rel));
    }

    // i18n
    final m = Map<String, dynamic>.from(manifest['i18n'] as Map);
    final def = m['default'] as String;
    final base = (await json('${m['dir']}/$def.json'))..remove('_meta');
    final i18n = <String, Map<String, String>>{def: base.map((k, v) => MapEntry(k, v as String))};
    for (final lang in List<String>.from(m['languages'] as List)) {
      if (lang == def) continue;
      final t = await src.read('${m['dir']}/$lang.json');
      if (t == null) continue;
      final over = Map<String, dynamic>.from(jsonDecode(t) as Map)..remove('_meta');
      i18n[lang] = {...i18n[def]!, ...over.map((k, v) => MapEntry(k, v as String))};
    }
    return CoreData._(version, manifest, tree, idx, files, prompts, promptJson, tools, schemas, i18n, macros);
  }

  static void _merge(Map<String, dynamic> base, Map<String, dynamic> extra, String where, Map<String, String> owner, String src) {
    for (final e in extra.entries) {
      final k = e.key;
      final v = e.value;
      final p = where.isEmpty ? k : '$where.$k';
      if (v is Map && base[k] is Map) {
        _merge(base[k] as Map<String, dynamic>, Map<String, dynamic>.from(v), p, owner, src);
      } else if (base.containsKey(k) && k != '_comment') {
        throw CoreError("config path '$p' is defined in both ${owner[p] ?? '?'} and $src");
      } else {
        base[k] = deepCopy(v);
        owner[p] = src;
      }
    }
  }

  static dynamic _walk(dynamic node, String dotted) {
    for (final part in dotted.split('.')) {
      if (node is! Map || !node.containsKey(part)) return null;
      node = node[part];
    }
    return node;
  }

  // ------------------------------------------------------------------ config / prompts / tools
  /// config("a.b.c") over the merged rules tree; missing -> [def].
  dynamic config(String dotted, [dynamic def]) => _walk(configTree, dotted) ?? def;

  String prompt(String name, [Map<String, Object?> values = const {}]) {
    var text = prompts[name];
    if (text == null) throw CoreError('unknown prompt $name');
    final v = Map<String, Object?>.from(values);
    if (name == 'system' && !v.containsKey('tools')) v['tools'] = toolsPrompt();
    for (final e in v.entries) {
      text = text!.replaceAll('{{${e.key}}}', '${e.value}');
    }
    return text!;
  }

  String toolsPrompt() {
    final byName = {for (final t in tools['tools'] as List) (t as Map)['name'] as String: t};
    return (tools['prompt_layout'] as List)
        .map((row) => (row as List).map((n) => (byName[n] as Map)['prompt'] as String).join(' | '))
        .join('\n');
  }

  /// The structured answer the AI must give: {say, tool, args}.
  Map<String, dynamic> actionSchema() {
    final resp = tools['response'] as Map;
    return {
      'type': 'object',
      'properties': {
        'say': {'type': 'string'},
        'tool': {
          'type': 'string',
          'enum': [resp['none_tool'], ...(tools['tools'] as List).map((t) => (t as Map)['name'])],
        },
        'args': {
          'type': 'object',
          'properties': {
            for (final e in (tools['args'] as Map).entries) e.key: {'type': (e.value as Map)['type']},
          },
        },
      },
      'required': List<String>.from(resp['required'] as List),
    };
  }

  Map<String, dynamic> schema(String name) => Map<String, dynamic>.from(schemas[name] as Map);

  int schemaVersion(String name) => ((schemas[name] as Map?)?['x-schema-version'] as num?)?.toInt() ?? 1;

  // ------------------------------------------------------------------ i18n
  Map<String, String> strings(String lang) => _i18n[lang] ?? _i18n[manifest['i18n']['default']]!;

  static final _ph = RegExp(r'\{([A-Za-z_][A-Za-z0-9_]*)\}');

  /// A UI/reply string with {placeholders} filled (falls back to English, then to the key).
  String t(String key, [String lang = 'en', Map<String, Object?> values = const {}]) {
    final s = strings(lang)[key] ?? strings('en')[key] ?? key;
    return s.replaceAllMapped(_ph, (m) => values.containsKey(m[1]) ? '${values[m[1]]}' : m[0]!);
  }

  // ------------------------------------------------------------------ regex dialect
  static final _forbidden = <(RegExp, String)>[
    (RegExp(r'\(\?<[=!]'), 'lookbehind'),
    (RegExp(r'\(\?>'), 'atomic group'),
    (RegExp(r'(?<!\\)[*+?}][+]'), 'possessive quantifier'),
    (RegExp(r'\(\?[aiLmsux-]+[):]'), 'inline flags'),
    (RegExp(r'\\[AZz]'), r'\A / \Z anchors (use ^ and $)'),
    (RegExp(r'\(\?P'), 'Python-only (?P...) syntax (write (?<name>...))'),
    (RegExp(r'\\k<|\(\?P='), 'named backreference'),
  ];
  static final _macro = RegExp(r'\{\{([A-Z_]+)\}\}');

  static void checkPortable(String pattern) {
    for (final (rx, what) in _forbidden) {
      if (rx.hasMatch(pattern)) throw CoreError('non-portable regex ($what): $pattern');
    }
  }

  /// Expand {{MACROS}} (up to 5 passes) -> portable source.
  String expand(String pattern) {
    for (var i = 0; i < 5; i++) {
      final next = pattern.replaceAllMapped(_macro, (m) => macros[m[1]] ?? m[0]!);
      if (next == pattern) break;
      pattern = next;
    }
    final left = _macro.firstMatch(pattern);
    if (left != null) throw CoreError('unknown macro ${left[0]} in $pattern');
    return pattern;
  }

  final Map<String, RegExp> _rxCache = {};

  RegExp compile(String pattern, {bool ignoreCase = true}) => _rxCache.putIfAbsent('$ignoreCase\u0000$pattern', () {
        final src = expand(pattern);
        checkPortable(src);
        return RegExp(src, caseSensitive: !ignoreCase);
      });

  String domainType(String name) {
    final d = (intentIndex['domains'] as Map)[name];
    if (d == null) throw CoreError('unknown intent domain $name');
    return (d as Map)['type'] as String;
  }

  /// Entries of a domain from every language file (first_match: stable-sorted by order).
  List<IntentEntry> entries(String name) => _domains.putIfAbsent(name, () {
        final kind = domainType(name);
        if (kind == 'words' || kind == 'map') throw CoreError('$name is a $kind domain');
        final out = <IntentEntry>[];
        for (final (fname, data) in intentFiles) {
          final ic = ((data['flags'] as Map?)?['ignore_case'] as bool?) ?? true;
          for (final e in ((data['domains'] as Map?)?[name] as List?) ?? const []) {
            final raw = Map<String, dynamic>.from(e as Map);
            out.add(kind == 'fragment'
                ? IntentEntry(raw, fname, source: expand(raw['pattern'] as String))
                : IntentEntry(raw, fname, rx: compile(raw['pattern'] as String, ignoreCase: ic)));
          }
        }
        if (kind == 'first_match') {
          return stableSorted(out, (a, b) => ((a['order'] as num?) ?? 0).compareTo((b['order'] as num?) ?? 0));
        }
        return out;
      }) as List<IntentEntry>;

  List<String> words(String name) => _domains.putIfAbsent(name, () {
        final out = <String>[];
        for (final (_, data) in intentFiles) {
          out.addAll(List<String>.from(((data['domains'] as Map?)?[name] as List?) ?? const []));
        }
        return out;
      }) as List<String>;

  Map<String, String> mapDomain(String name) => _domains.putIfAbsent(name, () {
        final out = <String, String>{};
        for (final (_, data) in intentFiles) {
          final m = (data['domains'] as Map?)?[name] as Map?;
          if (m != null) m.forEach((k, v) => out[k as String] = v as String);
        }
        return out;
      }) as Map<String, String>;

  bool anyMatch(String name, String text) => entries(name).any((e) => e.rx!.hasMatch(text));

  /// Remove the first match of each entry, in order.
  String strip(String name, String text) {
    for (final e in entries(name)) {
      text = text.replaceFirst(e.rx!, '');
    }
    return text;
  }

  /// Replace every match of each entry with its replace template, in order.
  String rewrite(String name, String text) {
    for (final e in entries(name)) {
      text = text.replaceAllMapped(e.rx!, (m) => expandTemplate(e.replace, m as RegExpMatch));
    }
    return text;
  }

  (IntentEntry, RegExpMatch)? firstMatch(String name, String text) {
    for (final e in entries(name)) {
      final m = e.rx!.firstMatch(text);
      if (m != null) return (e, m);
    }
    return null;
  }

  Iterable<(IntentEntry, RegExpMatch)> matches(String name, String text) sync* {
    for (final e in entries(name)) {
      final m = e.rx!.firstMatch(text);
      if (m != null) yield (e, m);
    }
  }

  /// text[:start] + expand(replace) + text[end:]
  static String replaceWith(IntentEntry e, RegExpMatch m) =>
      m.input.substring(0, m.start) + expandTemplate(e.replace, m) + m.input.substring(m.end);

  /// `$1`…`$99` and `${name}`; a group that did not participate is empty.
  static String expandTemplate(String tmpl, RegExpMatch m) {
    final out = StringBuffer();
    var i = 0;
    while (i < tmpl.length) {
      final c = tmpl[i];
      if (c == r'$' && i + 1 < tmpl.length) {
        if (tmpl[i + 1] == '{') {
          final end = tmpl.indexOf('}', i + 2);
          if (end > 0) {
            final name = tmpl.substring(i + 2, end);
            if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) {
              out.write(_named(m, name) ?? '');
              i = end + 1;
              continue;
            }
          }
        } else if (_isDigit(tmpl.codeUnitAt(i + 1))) {
          var j = i + 1;
          while (j < tmpl.length && _isDigit(tmpl.codeUnitAt(j))) {
            j++;
          }
          final g = int.parse(tmpl.substring(i + 1, j));
          out.write(g <= m.groupCount ? (m.group(g) ?? '') : '');
          i = j;
          continue;
        }
      }
      out.write(c);
      i++;
    }
    return out.toString();
  }

  static bool _isDigit(int c) => c >= 48 && c <= 57;

  static String? _named(RegExpMatch m, String name) => m.groupNames.contains(name) ? m.namedGroup(name) : null;

  /// A named group's text or null (also when the pattern has no such group).
  static String? group(RegExpMatch m, String name) => _named(m, name);

  /// The domain's fragment sources concatenated.
  String fragment(String name) => entries(name).map((e) => e.source!).join();

  dynamic slotValues(String dotted) {
    dynamic node = intentIndex['slot_values'];
    for (final part in dotted.split('.')) {
      node = (node as Map)[part];
    }
    return node;
  }

  /// (file, domain, id, expanded source) for every pattern (conformance format checks).
  List<(String, String, String?, String)> allPatterns() {
    final out = <(String, String, String?, String)>[];
    final doms = intentIndex['domains'] as Map;
    for (final (fname, data) in intentFiles) {
      for (final d in ((data['domains'] as Map?) ?? const {}).entries) {
        final type = (doms[d.key] as Map?)?['type'];
        if (type == 'words' || type == 'map') continue;
        for (final e in d.value as List) {
          out.add((fname, d.key as String, (e as Map)['id'] as String?, expand(e['pattern'] as String)));
        }
      }
    }
    return out;
  }
}
