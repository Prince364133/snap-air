import 'dart:io';

import 'package:snapy/i18n/i18n.dart';

/// English strings straight from the asset files (tests run from mobile/): the shared
/// en.json (copied from core/i18n) with the Flutter screens' en.ui.json on top, like the app.
void useEnglish() {
  final en = File('assets/i18n/en.json').readAsStringSync();
  final ui = File('assets/i18n/en.ui.json');
  I18n.notifier.value = I18n.fromLayers('en', en, ui.existsSync() ? ui.readAsStringSync() : null);
}

/// Every English string the app can show (both layers), lower-cased, for wording checks.
String allEnglishText() {
  final parts = [for (final f in ['assets/i18n/en.json', 'assets/i18n/en.ui.json']) if (File(f).existsSync()) File(f).readAsStringSync()];
  return parts.join('\n').toLowerCase();
}
