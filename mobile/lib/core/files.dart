import 'dart:convert';
import 'dart:io';

import 'snapy_core.dart';

/// Snapy's private folder on the phone (…/files/snapy), the same folder the brain and the
/// Kotlin counter use. Small JSON helpers for the screens that keep their own data
/// (daily three, rules cache, receipts). Tests point [overrideRoot] at a temp folder.
class SnapyFiles {
  static Directory? overrideRoot;
  static Directory? _root;

  static Future<Directory> root() async {
    final o = overrideRoot;
    if (o != null) return o;
    final r = _root;
    if (r != null) return r;
    final base = await SnapyCore.filesDir();
    return _root = Directory('$base/snapy')..createSync(recursive: true);
  }

  static Future<File> file(String relative) async {
    final f = File('${(await root()).path}/$relative');
    f.parent.createSync(recursive: true);
    return f;
  }

  static Future<dynamic> readJson(String relative) async {
    try {
      final f = await file(relative);
      if (!f.existsSync()) return null;
      return jsonDecode(await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  static Future<void> writeJson(String relative, Object? value) async {
    final f = await file(relative);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(value));
    await tmp.rename(f.path);
  }
}
