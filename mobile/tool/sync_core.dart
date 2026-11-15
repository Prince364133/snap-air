// Copies the shared core into the Flutter package, because Flutter assets can't reference
// files outside the package:
//   ../core/**  (everything the runtime loads, NOT conformance/)  -> assets/core/
//                + assets/core/_files.json (an asset bundle can't list folders)
//   ../core/i18n/*.json -> assets/i18n/    (UI strings; Kotlin Strings.kt reads them too)
//   ../core/rules/**    -> assets/rules/   (kept for existing readers)
// Conformance cases stay in ../core/conformance: the tests read them from the repo.
//
// Run from mobile/:   dart run tool/sync_core.dart          (copy)
//                     dart run tool/sync_core.dart --check  (exit 1 if anything is out of date; for CI)
//
// Files that exist only in the destination are left alone and listed, so a missing core
// file never silently deletes the app's bundled copy (assets/rules/realcount.json is app-only).
import 'dart:convert';
import 'dart:io';

const runtimeFolders = ['rules', 'intents', 'prompts', 'tools', 'schemas', 'i18n'];
const runtimeFiles = ['manifest.json', 'VERSION', 'README.md'];

void main(List<String> args) {
  final check = args.contains('--check');
  final mobile = _mobileDir();
  final core = Directory('${mobile.parent.path}/core');
  if (!core.existsSync()) {
    stderr.writeln('No ${core.path} yet — keeping the bundled assets as they are.');
    exit(0);
  }
  var changed = 0, problems = 0;

  bool copy(File f, String rel, String to) {
    final text = f.readAsStringSync().replaceAll('\r\n', '\n');
    if (rel.endsWith('.json')) {
      try {
        jsonDecode(text);
      } catch (e) {
        stderr.writeln('BAD JSON core/$rel: $e');
        problems++;
        return false;
      }
    }
    final out = File('${mobile.path}/$to');
    if (out.existsSync() && out.readAsStringSync() == text) return true;
    changed++;
    if (check) {
      stdout.writeln('stale $to');
    } else {
      out.parent.createSync(recursive: true);
      out.writeAsStringSync(text);
      stdout.writeln('copy  core/$rel -> $to');
    }
    return true;
  }

  // 1. the runtime's copy of core/
  final index = <String>[];
  for (final name in runtimeFiles) {
    final f = File('${core.path}/$name');
    if (f.existsSync() && copy(f, name, 'assets/core/$name')) index.add(name);
  }
  for (final folder in runtimeFolders) {
    final src = Directory('${core.path}/$folder');
    if (!src.existsSync()) {
      stdout.writeln('skip  core/$folder (not there)');
      continue;
    }
    final files = src.listSync(recursive: true).whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final rel = '$folder/${f.path.substring(src.path.length + 1).replaceAll('\\', '/')}';
      if (rel.contains('/.')) continue;
      if (copy(f, rel, 'assets/core/$rel')) index.add(rel);
    }
  }
  final idxText = '${const JsonEncoder.withIndent(' ').convert(index)}\n';
  final idxFile = File('${mobile.path}/assets/core/_files.json');
  if (!idxFile.existsSync() || idxFile.readAsStringSync() != idxText) {
    changed++;
    if (check) {
      stdout.writeln('stale assets/core/_files.json');
    } else {
      idxFile.parent.createSync(recursive: true);
      idxFile.writeAsStringSync(idxText);
    }
  }
  final keep = index.toSet()..add('_files.json');
  final dst = Directory('${mobile.path}/assets/core');
  if (dst.existsSync()) {
    for (final f in dst.listSync(recursive: true).whereType<File>()) {
      final rel = f.path.substring(dst.path.length + 1).replaceAll('\\', '/');
      if (!keep.contains(rel)) stdout.writeln('keep  assets/core/$rel (not in core/ any more)');
    }
  }

  // 2. the older flat copies (UI strings, Kotlin)
  for (final (from, to) in [('i18n', 'assets/i18n'), ('rules', 'assets/rules')]) {
    final src = Directory('${core.path}/$from');
    if (!src.existsSync()) continue;
    for (final f in src.listSync(recursive: true).whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.json')) continue;
      final rel = f.path.substring(src.path.length + 1).replaceAll('\\', '/');
      copy(f, '$from/$rel', '$to/$rel');
    }
  }
  stdout.writeln(check ? '$changed out of date' : '$changed copied');
  exit(problems > 0 || (check && changed > 0) ? 1 : 0);
}

/// mobile/ — this script lives in mobile/tool/.
Directory _mobileDir() {
  final script = File.fromUri(Platform.script);
  final d = script.parent.parent;
  return File('${d.path}/pubspec.yaml').existsSync() ? d : Directory.current;
}
