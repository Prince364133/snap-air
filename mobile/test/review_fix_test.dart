// The review-and-fix pass (docs/ANDROID_NEXT_PLAN.md §12): Reel counter health card, the
// Diagnostics screen, the volume-key shortcut guide and the meeting-audio upload switch.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapy/core/next_api.dart';
import 'package:snapy/ui/a11y_health_card.dart';
import 'package:snapy/ui/diagnostics_page.dart';
import 'package:snapy/ui/profile_store.dart';
import 'package:snapy/ui/profile_tab.dart';
import 'package:snapy/ui/settings_page.dart';

import 'helpers.dart';

class Fake {
  final calls = <MethodCall>[];
  Map<String, dynamic> modes = {'wake': false, 'volume': true, 'power': false, 'assistantRole': false, 'shortcut': false};
  List<Map<String, dynamic>> crashes = [
    {'file': 'crash-1.txt', 'text': 'time=1\nwhere=a11y.event\njava.lang.IllegalStateException: boom'},
  ];
  bool hasHealth = true;

  Iterable<MethodCall> named(String m) => calls.where((c) => c.method == m);

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'status':
        return <String, bool>{};
      case 'rcPrefs':
        return '{}';
      case 'device':
        return {'manufacturer': 'Xiaomi', 'sdk': 34};
      case 'profile':
        return {'name': '', 'assistant_name': 'Snapy'};
      case 'activationModes':
        return modes;
      case 'brainStatus':
        return '{"provider": "gemini", "providers": {"gemini": "Google Gemini"}, "meeting_audio_upload": false}';
      case 'a11yHealth':
        if (!hasHealth) throw MissingPluginException();
        return {'state': 'stopped', 'enabled': true, 'connected': false, 'crash_count': 1, 'manufacturer': 'Xiaomi'};
      case 'crashReports':
        return crashes;
      case 'clearCrashReports':
        crashes = [];
        return true;
    }
    return null;
  }
}

late Fake fake;

Widget app(Widget home) => MaterialApp(home: home);

void main() {
  setUpAll(useEnglish);
  setUp(() {
    fake = Fake();
    ProfileStore.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(NextApi.channel, fake.handle);
  });

  test('a11yHealth: parsed, and null when the Kotlin side is older', () async {
    final h = await NextApi.a11yHealth();
    expect(h?.stopped, isTrue);
    expect(h?.manufacturer, 'Xiaomi');
    fake.hasHealth = false;
    expect(await NextApi.a11yHealth(), isNull);
    expect(A11yHealthCard.wanted(null, true), isFalse);
    expect(A11yHealthCard.wanted(const A11yHealth(state: 'on'), true), isFalse);
    expect(A11yHealthCard.wanted(const A11yHealth(state: 'off'), false), isFalse);   // the setup banner covers it
    expect(A11yHealthCard.wanted(const A11yHealth(state: 'off'), true), isTrue);     // sideload block
  });

  testWidgets('health card: stopped -> brand steps + back to Accessibility settings', (tester) async {
    await tester.pumpWidget(app(Scaffold(
      body: A11yHealthCard(health: const A11yHealth(state: 'stopped', manufacturer: 'Xiaomi'), restricted: false, onSideloadGuide: () {}),
    )));
    expect(find.text("Your phone stopped Snapy's Reel counter"), findsOneWidget);
    expect(find.textContaining('Autostart'), findsOneWidget);
    await tester.tap(find.text('Turn the Reel counter back on'));
    await tester.pump();
    expect(fake.named('openRealCountSettings'), isNotEmpty);
  });

  testWidgets('health card: off + restricted settings -> the sideload guide', (tester) async {
    var opened = 0;
    await tester.pumpWidget(app(Scaffold(
      body: A11yHealthCard(health: const A11yHealth(state: 'off'), restricted: true, onSideloadGuide: () => opened++),
    )));
    await tester.tap(find.text('Show me how'));
    expect(opened, 1);
  });

  testWidgets('diagnostics: lists crash reports and clears them', (tester) async {
    await tester.pumpWidget(app(const DiagnosticsPage()));
    await tester.pump();
    expect(find.text('crash-1.txt'), findsOneWidget);
    expect(find.text('Switched on, but stopped by the phone'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('diag-clear')));
    await tester.pump();
    await tester.pump();
    expect(fake.named('clearCrashReports'), isNotEmpty);
    expect(find.text('No crash reports. Everything has run smoothly.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('profile: no volume-key mode (it would remove the Reel counter switch)', (tester) async {
    await tester.pumpWidget(app(const ProfileTab()));
    await tester.pump();
    expect(find.byIcon(Icons.volume_up_outlined, skipOffstage: false), findsNothing);
    expect(find.byKey(const ValueKey('volume-shortcut-guide'), skipOffstage: false), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('settings: meeting audio upload is off, and turning it on needs the disclosure', (tester) async {
    tester.view.physicalSize = const Size(2400, 27000);              // 800 dp wide, like the other Settings tests
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(const SettingsPage()));
    await tester.pump();
    final sw = find.byKey(const ValueKey('meeting-audio-upload'));
    expect(tester.widget<SwitchListTile>(sw).value, isFalse);
    await tester.tap(sw);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('upload its audio recording to Google Gemini'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(fake.named('updateSettings'), isEmpty);                       // declined: nothing changes

    await tester.tap(sw);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(FilledButton, 'Turn on'));
    await tester.pump(const Duration(milliseconds: 300));
    final sent = jsonDecode((fake.named('updateSettings').last.arguments as Map)['json'] as String) as Map;
    expect(sent, {'meeting_audio_upload': true});
  });
}
