import 'dart:io';

import 'package:snapy/i18n/i18n.dart';

/// English strings straight from the asset file (tests run from mobile/).
void useEnglish() {
  final en = File('assets/i18n/en.json').readAsStringSync();
  I18n.notifier.value = I18n.fromJson('en', en);
}
