import 'dart:ui';

import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'ui/home_page.dart';
import 'ui/sheet_page.dart';

void main() => runApp(SnapyApp(sheet: PlatformDispatcher.instance.defaultRouteName == '/sheet'));

class SnapyApp extends StatelessWidget {
  /// true when opened from the pill over another app (SheetActivity).
  final bool sheet;
  const SnapyApp({super.key, this.sheet = false});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Snapy',
      debugShowCheckedModeBanner: false,
      theme: snapyTheme(Brightness.light),
      darkTheme: snapyTheme(Brightness.dark),
      themeMode: ThemeMode.system, // follows the phone, like the Windows HUD follows Windows
      color: sheet ? Colors.transparent : null,
      home: sheet ? const SheetPage() : const HomePage(),
    );
  }
}
