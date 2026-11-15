import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/theme.dart';
import 'i18n/i18n.dart';
import 'realcount/realcount_data.dart';
import 'ui/home_page.dart';
import 'ui/reset_page.dart';
import 'ui/sheet_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var lang = 'auto';
  var simple = false;
  try {
    final p = await RealCountRepo.prefs().timeout(const Duration(seconds: 2));
    lang = p.s('ui_lang');
    simple = p.b('simple_mode');
  } catch (_) {}
  await I18n.use(I18n.resolve(lang, PlatformDispatcher.instance.locale.languageCode));
  SnapyApp.simple.value = simple;
  // SheetActivity is single-task: a new chip tap / reset / pause arrives here instead of a new window
  const MethodChannel('snapy/sheet').setMethodCallHandler((call) async {
    if (call.method == 'route') SnapyApp.navigateTo('${call.arguments}');
  });
  runApp(SnapyApp(route: PlatformDispatcher.instance.defaultRouteName));
}

class SnapyApp extends StatelessWidget {
  /// '/', '/sheet' (from the chip), '/reset?app=…', '/break?app=…&s=10'.
  final String route;
  const SnapyApp({super.key, bool sheet = false, String? route}) : route = route ?? (sheet ? '/sheet' : '/');

  /// Big-text & simple mode (Settings → Chip & nudges).
  static final ValueNotifier<bool> simple = ValueNotifier(false);
  static final navigatorKey = GlobalKey<NavigatorState>();

  bool get overlay => route != '/' && route.isNotEmpty;

  static void navigateTo(String route) {
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    nav.pushAndRemoveUntil(PageRouteBuilder(
      opaque: false,
      pageBuilder: (_, _, _) => pageFor(route),
      transitionDuration: Duration.zero,
    ), (_) => false);
  }

  static Widget pageFor(String route) {
    final uri = Uri.tryParse(route) ?? Uri(path: '/');
    final q = uri.queryParameters;
    switch (uri.path) {
      case '/sheet':
        return const SheetPage();
      case '/reset':
        return ResetPage(app: q['app'], overlay: true);
      case '/break':
        return BreakPage(app: q['app'] ?? '', seconds: int.tryParse(q['s'] ?? '') ?? 10);
      default:
        return const HomePage();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([I18n.notifier, simple]),
      builder: (context, _) => MaterialApp(
        title: 'Snapy',
        navigatorKey: navigatorKey,
        debugShowCheckedModeBanner: false,
        theme: snapyTheme(Brightness.light),
        darkTheme: snapyTheme(Brightness.dark),
        themeMode: ThemeMode.system, // follows the phone, like the Windows HUD follows Windows
        color: overlay ? Colors.transparent : null,
        locale: Locale(I18n.current.lang),
        supportedLocales: [for (final l in I18n.supported) Locale(l)],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (context, child) {
          if (!simple.value) return child!;
          final mq = MediaQuery.of(context);
          return MediaQuery(data: mq.copyWith(textScaler: TextScaler.linear(mq.textScaler.scale(1) * 1.25)), child: child!);
        },
        home: pageFor(route),
      ),
    );
  }
}
