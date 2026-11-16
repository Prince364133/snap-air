import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapy/main.dart';
import 'package:snapy/realcount/habits.dart';
import 'package:snapy/ui/chip_settings.dart';
import 'package:snapy/ui/onboarding.dart';
import 'package:snapy/ui/report_page.dart';
import 'package:snapy/ui/reset_page.dart';
import 'package:snapy/ui/settings_page.dart';

import 'helpers.dart';

void main() {
  setUpAll(useEnglish);

  testWidgets('home shows Real Count, tasks, memory and the assistant button', (tester) async {
    await tester.pumpWidget(const SnapyApp());
    await tester.pump();
    expect(find.widgetWithText(FilledButton, 'Snapy'), findsOneWidget);
    expect(find.text('Usage Frequency'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Top Used Apps'), 300);
    expect(find.text('Top Used Apps'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());                     // dispose timers
  });

  testWidgets('sheet over other apps shows the assistant', (tester) async {
    await tester.pumpWidget(const SnapyApp(sheet: true));
    await tester.pump();
    expect(find.text('Snapy'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('settings offers the three AI brain modes and a key field', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pump();
    expect(find.text('AI Brain Intelligence'), findsOneWidget);
    expect(find.text('Your API is not connected till now'), findsOneWidget);
    expect(find.text('Save API Key'), findsOneWidget);
  });

  test('reset phases: breathe, stand, water', () {
    expect(resetPhase(0, 120), 'breathe_in');
    expect(resetPhase(5, 120), 'hold');
    expect(resetPhase(10, 120), 'breathe_out');
    expect(resetPhase(14, 120), 'breathe_in');
    expect(resetPhase(60, 120), 'stand');
    expect(resetPhase(95, 120), 'water');
    expect(resetPhase(120, 120), 'done');
  });

  testWidgets('the 2-minute reset can always be skipped and unlocks at the end', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ResetPage(seconds: 4)));
    expect(find.text('Breathe in'), findsOneWidget);
    expect(find.text('Skip the reset'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Have a sip of water'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Nice. You’re good to go.'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the opt-in pause opens the app after 10 seconds, "Not now" any time', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: BreakPage(app: 'Instagram', seconds: 10)));
    final open = find.widgetWithText(FilledButton, 'Open Instagram');
    expect(tester.widget<FilledButton>(open).onPressed, isNull);
    expect(find.text('Not now'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    expect(tester.widget<FilledButton>(open).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('permission cards: plan order, the Reel counter disclosure, every card skippable', (tester) async {
    expect(permCards.map((s) => s.id), ['counter', 'overlay', 'usage', 'mic', 'notifications']);
    tester.view.physicalSize = const Size(1200, 7000);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: const OnboardingFlow(isInitialSetup: false),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('Reel counter'), findsOneWidget);
    expect(find.text('Count Reels and Shorts. Never reads messages or what you type.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Agree and continue'), findsOneWidget);
    await tester.tap(find.text('Skip for now'));
    await tester.pump();
    expect(find.text('Chip by the camera'), findsOneWidget);
  });

  testWidgets('chip settings: size, nudges, creator mode, pause and simple mode', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChipSettingsPage()));
    await tester.pump();
    expect(find.text('Show the chip'), findsOneWidget);
    expect(find.text('Large'), findsOneWidget);
    expect(find.text('On the camera'), findsOneWidget);                 // chip style
    await tester.scrollUntilVisible(find.text('Creator mode'), 300);
    expect(find.text('Gentle nudges', skipOffstage: false), findsWidgets);
    expect(find.text('Creator mode'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Big text & simple mode'), 300);
    expect(find.text('Big text & simple mode'), findsOneWidget);
  });

  testWidgets('weekly card compares only with yourself', (tester) async {
    final r = WeeklyReport.build([
      DayStat(DateTime(2026, 11, 15), screenMs: 3600000, reels: 10),
      DayStat(DateTime(2026, 11, 7), screenMs: 7200000, reels: 30),
    ], DateTime(2026, 11, 15));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListView(children: [WeeklyCard(report: r), const StreakCard(streak: StreakResult(4, 1))]))));
    expect(find.text('50% less screen time than your last week.'), findsOneWidget);
    expect(find.text('Compared only with your own last week.'), findsOneWidget);
    expect(find.text('4-day streak'), findsOneWidget);
    expect(find.text('One miss forgiven this week. The streak lives on.'), findsOneWidget);
  });
}
