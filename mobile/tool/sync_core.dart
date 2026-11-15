// Copies the shared product data into the Flutter package, because Flutter assets can't
// reference files outside the package:
//   ../core/i18n/*.json  -> assets/i18n/
//   ../core/rules/**     -> assets/rules/
//
// Run from mobile/:   dart run tool/sync_core.dart          (copy)
//                     dart run tool/sync_core.dart --check  (exit 1 if anything is out of date; for CI)
//
// Only JSON files are copied. Files that exist only in assets/ (not in core/) are left alone
// and listed, so a missing core file never silently deletes the app's bundled copy.
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final check = args.contains('--check');
  final mobile = _mobileDir();
  final core = Directory('${mobile.parent.path}/core');
  if (!core.existsSync()) {
    stderr.writeln('No ${core.path} yet — keeping the bundled assets as they are.');
    exit(0);
  }
  var changed = 0, problems = 0;
  for (final (from, to) in [('i18n', 'assets/i18n'), ('rules', 'assets/rules')]) {
    final src = Directory('${core.path}/$from');
    if (!src.existsSync()) {
      stdout.writeln('skip  core/$from (not there)');
      continue;
    }
    final dst = Directory('${mobile.path}/$to')..createSync(recursive: true);
    final seen = <String>{};
    for (final f in src.listSync(recursive: true).whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.json')) continue;
      final rel = f.path.substring(src.path.length + 1).replaceAll('\\', '/');
      seen.add(rel);
      final text = f.readAsStringSync();
      try {
        jsonDecode(text);
      } catch (e) {
        stderr.writeln('BAD JSON core/$from/$rel: $e');
        problems++;
        continue;
      }
      final out = File('${dst.path}/$rel');
      if (out.existsSync() && out.readAsStringSync() == text) continue;
      changed++;
      if (check) {
        stdout.writeln('stale $to/$rel');
      } else {
        out.parent.createSync(recursive: true);
        out.writeAsStringSync(text);
        stdout.writeln('copy  core/$from/$rel -> $to/$rel');
      }
    }
    for (final f in dst.listSync(recursive: true).whereType<File>()) {
      final rel = f.path.substring(dst.path.length + 1).replaceAll('\\', '/');
      if (!seen.contains(rel)) stdout.writeln('keep  $to/$rel (only in the app)');
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
