// Shared helpers for the core runtime tests: load ../core straight from the repo.
import 'dart:convert';
import 'dart:io';

import 'package:snapy/core_runtime/core_data.dart';
import 'package:snapy/core_runtime/py.dart';

/// mobile/ when tests run from the package root (flutter test).
String repoCoreDir() {
  for (final c in ['../core', 'core', '../../core']) {
    if (File('$c/manifest.json').existsSync()) return Directory(c).absolute.path;
  }
  throw StateError('core/ not found from ${Directory.current.path}');
}

CoreData? _cached;

Future<CoreData> loadRepoCore() async => _cached ??= await CoreData.load(DirCoreSource(repoCoreDir()));

/// Every core/conformance/*.json (sync/ and other sub-folders are not runtime suites).
Map<String, Map<String, dynamic>> loadConformanceSuites() {
  final dir = Directory('${repoCoreDir()}/conformance');
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return {
    for (final f in files)
      f.uri.pathSegments.last.replaceAll('.json', ''): Map<String, dynamic>.from(jsonDecode(f.readAsStringSync()) as Map),
  };
}

String isoMinutesOf(DateTime d) => isoMinutes(d);

String tempDir(String name) => Directory.systemTemp.createTempSync('snapy_$name').path;
