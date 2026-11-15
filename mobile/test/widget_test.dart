import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapy/main.dart';
import 'package:snapy/ui/settings_page.dart';

void main() {
  testWidgets('home shows Real Count, tasks, memory and the assistant button', (tester) async {
    await tester.pumpWidget(const SnapyApp());
    await tester.pump();
    expect(find.text('Real Count'), findsOneWidget);
    expect(find.text('Turn on Real Count'), findsOneWidget);     // no permissions in tests
    expect(find.text('Tasks'), findsOneWidget);
    expect(find.text('What Snapy remembers'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Ask Snapy'), 300);
    expect(find.text('Ask Snapy'), findsOneWidget);
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
    expect(find.text('On this phone'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Cloud'), findsOneWidget);
    expect(find.text('Save key'), findsOneWidget);
  });
}
