// Widget tests for the next-generation UI (docs/ANDROID_NEXT_PLAN.md §1–§2, §9):
// the 3 tabs, reel limits (soft / hard), the API key messages, onboarding (happy path,
// every skip, resume refresh, OEM notes), profile rename and the memory vault.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapy/core/next_api.dart';
import 'package:snapy/ui/app_limits_page.dart';
import 'package:snapy/ui/main_scaffold.dart';
import 'package:snapy/ui/onboarding.dart';
import 'package:snapy/ui/profile_store.dart';
import 'package:snapy/ui/profile_tab.dart';
import 'package:snapy/ui/settings_page.dart';
import 'package:snapy/ui/vault_page.dart';

import 'helpers.dart';

/// A pretend Kotlin side of `snapy/core`: canned answers, and a log of every call.
class FakeCore {
  final calls = <MethodCall>[];
  Map<String, bool> status = {};
  Map<String, dynamic> key = {'ok': true, 'code': 'ok'};
  Map<String, dynamic> device = {'manufacturer': 'Google', 'brand': 'google', 'sdk': 34};
  bool restricted = false;
  bool hasSetReelLimit = true;
  Map<String, dynamic> reelLimits = {
    'com.instagram.android': {'limit': 30, 'mode': 'soft', 'used': 4, 'state': 'ok'},
  };
  List<Map<String, dynamic>> vault = [];

  Iterable<MethodCall> named(String m) => calls.where((c) => c.method == m);
  Map args(String m) => named(m).last.arguments as Map;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final a = call.arguments is Map ? call.arguments as Map : const {};
    switch (call.method) {
      case 'status':
        return status;
      case 'rcPrefs':
        return '{"onboarding_done": true}';
      case 'device':
        return device;
      case 'isRestrictedSettings':
        return restricted;
      case 'profile':
        return {'name': '', 'assistant_name': 'Snapy'};
      case 'setProfile':
        return {...a};
      case 'activationModes':
        return {'wake': false, 'volume': false, 'power': false, 'assistantRole': false};
      case 'setActivationMode':
        return {'wake': a['mode'] == 'wake' && a['on'] == true};
      case 'testApiKey':
        return key;
      case 'brainStatus':
        return '{"provider": "gemini", "providers": {"gemini": "Google Gemini"}, "mode": "auto"}';
      case 'vaultList':
        return vault;
      case 'vaultExport':
        return '/data/snapy/vault/${a['kind']}.md';
      case 'vaultClear':
        vault = [];
        return true;
      case 'getInstalledApps':
        return [
          {'package': 'com.instagram.android', 'label': 'Instagram', 'is_social': true},
        ];
      case 'setReelLimit':
        if (!hasSetReelLimit) throw MissingPluginException();
        return true;
      case 'reelLimits':
        return reelLimits;
      case 'shortVideoApps':
        return [
          {'package': 'com.instagram.android', 'label': 'Instagram', 'kind': 'Reels', 'installed': true},
        ];
      case 'setAppReelLimit':
        return true;
      case 'snapshot':
        return '{"tasks": [], "memories": [], "notes": []}';
    }
    return null;
  }
}

late FakeCore core;

Widget app(Widget home) => MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: home),
      ),
    );

/// A very tall test screen, so lazy lists build every card (no scrolling needed to find things).
void tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 7000);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(useEnglish);

  setUp(() {
    core = FakeCore();
    ProfileStore.reset();
    NextApi.clearIconCache();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(NextApi.channel, core.handle);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(NextApi.channel, null);
  });

  // ------------------------------------------------------------------ tabs

  testWidgets('3 tabs: Home · Tools · Profile, switching keeps each tab\'s state', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(const MainScaffold(checkOnboarding: false)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Home'), findsWidgets);
    expect(find.text('Tools'), findsOneWidget);
    expect(find.text('Profile'), findsWidgets);

    await tester.tap(find.text('Tools'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Tools & Habits'), findsOneWidget);
    expect(find.text('Meeting assistant', skipOffstage: false), findsOneWidget);
    expect(find.text('Quick actions', skipOffstage: false), findsOneWidget);

    await tester.tap(find.text('Profile').last);
    await tester.pump(const Duration(milliseconds: 300));
    final ice = find.byKey(const ValueKey('ice-notes'), skipOffstage: false);
    await tester.scrollUntilVisible(ice, 300, scrollable: find.byType(Scrollable).last);
    await tester.enterText(ice, 'O+ blood');

    await tester.tap(find.text('Home').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Profile').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('O+ blood', skipOffstage: false), findsOneWidget);      // IndexedStack kept it
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  // ------------------------------------------------------------------ reel limits

  testWidgets('reel limits: hard lock and soft nudge reach the phone', (tester) async {
    tall(tester);
    await tester.pumpWidget(app(const AppLimitsPage()));
    await tester.pump();
    await tester.tap(find.text('Instagram'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // soft by default (§3): the hard lock is opt-in and says only the reels feed is blocked
    expect(find.text('Lock the reels feed at the limit'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('hard-lock'))).value, isFalse);
    expect(find.textContaining('DMs and the rest of Instagram keep working'), findsOneWidget);
    await tester.ensureVisible(find.text('Save Boundaries'));
    await tester.tap(find.text('Save Boundaries'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(core.args('setReelLimit'), {'package': 'com.instagram.android', 'limit': 30, 'mode': 'soft'});
    expect(core.args('setRcPrefs')['json'], isNot(contains('lock_')));        // one store: no legacy lock_ prefs

    await tester.tap(find.text('Instagram'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Lock the reels feed at the limit'));          // opt in
    await tester.pump();
    expect(find.textContaining('only the reels / shorts feed in Instagram is blocked'), findsOneWidget);
    await tester.ensureVisible(find.text('Save Boundaries'));
    await tester.tap(find.text('Save Boundaries'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(core.args('setReelLimit'), {'package': 'com.instagram.android', 'limit': 30, 'mode': 'hard'});
    await tester.pump(const Duration(seconds: 5));                            // snackbar
  });

  testWidgets('reel limits: no limit yet = off, and the lock can only be armed with a limit', (tester) async {
    tall(tester);
    core.reelLimits = {};
    await tester.pumpWidget(app(const AppLimitsPage()));
    await tester.pump();
    await tester.tap(find.text('Instagram'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Disabled (off)'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('hard-lock'))).onChanged, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('NextApi.setReelLimit sends §9 soft/hard, falls back to the older method', () async {
    expect(await NextApi.setReelLimit('com.instagram.android', 30, 'hard'), isTrue);
    expect(core.args('setReelLimit'), {'package': 'com.instagram.android', 'limit': 30, 'mode': 'hard'});
    core.hasSetReelLimit = false;
    expect(await NextApi.setReelLimit('com.google.android.youtube', 0, 'soft'), isTrue);
    expect(core.args('setAppReelLimit'), {'package': 'com.google.android.youtube', 'limit': 0, 'lock': false});
  });

  // ------------------------------------------------------------------ API key

  test('key codes map to the plan\'s table', () {
    KeyVerdict v(String code, [String msg = '']) => KeyTestResult(ok: code == 'ok', code: code, message: msg).verdict;
    expect(v('ok'), KeyVerdict.ok);
    for (final c in ['invalid_key', 'API_KEY_INVALID', '400', '401', '403']) {
      expect(v(c), KeyVerdict.invalid, reason: c);
    }
    expect(v('permission'), KeyVerdict.permission);
    expect(v('PERMISSION_DENIED'), KeyVerdict.permission);
    expect(v('quota'), KeyVerdict.quota);
    expect(v('RESOURCE_EXHAUSTED'), KeyVerdict.quota);
    expect(v('429'), KeyVerdict.quota);
    expect(v('FAILED_PRECONDITION'), KeyVerdict.region);
    expect(v('error', 'User location is not supported'), KeyVerdict.region);
    expect(v('network'), KeyVerdict.network);
    expect(v('model'), KeyVerdict.error);
  });

  const table = {
    'ok': ("Connected — Snapy's AI brain is ready.", null),
    'invalid_key': ("This key isn't valid. Copy it again, or create a new one.", 'Get a new key'),
    'permission': ("This key can't use the Gemini API. Enable it or create a new key.", 'Get a new key'),
    'quota': ("This key's free quota is used up. Wait, or use another key.", 'Get a new key'),
    'FAILED_PRECONDITION': ("Gemini isn't available for this key's region.", 'Help'),
    'network': ("No internet — try again when you're online.", 'Retry'),
  };
  for (final e in table.entries) {
    testWidgets('API key test "${e.key}" shows the exact message', (tester) async {
      core.key = {'ok': e.key == 'ok', 'code': e.key, 'message': 'raw'};
      await tester.pumpWidget(app(const SettingsPage()));
      await tester.pump();
      final field = find.byKey(const ValueKey('api-key'));
      await tester.ensureVisible(field);
      await tester.enterText(field, 'AIza-test');
      final test = find.text('Test Connection');
      await tester.ensureVisible(test);
      await tester.tap(test);
      await tester.pump();
      await tester.pump();
      expect(core.args('testApiKey'), {'provider': 'gemini', 'key': 'AIza-test'});
      expect(find.text(e.value.$1, skipOffstage: false), findsOneWidget);
      if (e.value.$2 != null) expect(find.text(e.value.$2!, skipOffstage: false), findsOneWidget);
    });
  }

  testWidgets('"Get a new key" opens aistudio.google.com/apikey', (tester) async {
    core.key = {'ok': false, 'code': 'invalid_key'};
    await tester.pumpWidget(app(const SettingsPage()));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('api-key')), 'bad');
    await tester.ensureVisible(find.text('Test Connection'));
    await tester.tap(find.text('Test Connection'));
    await tester.pump();
    await tester.pump();
    await tester.ensureVisible(find.text('Get a new key'));
    await tester.tap(find.text('Get a new key'));
    await tester.pump();
    final open = core.named('openUrl').single.arguments as Map;
    expect(open['url'], 'https://aistudio.google.com/apikey');
    await tester.pump(const Duration(seconds: 5));
  });

  // ------------------------------------------------------------------ onboarding

  Future<void> tapText(WidgetTester tester, String text) async {
    final f = find.text(text).last;
    await tester.ensureVisible(f);
    await tester.tap(f);
    await tester.pump();
  }

  Future<void> skipCard(WidgetTester tester) => tapText(tester, 'Skip for now');

  testWidgets('onboarding happy path: name → assistant → cards → confetti → saved', (tester) async {
    tall(tester);
    await tester.pumpWidget(app(const OnboardingFlow()));
    await tester.pump();
    expect(find.text("Hey! What's your name?"), findsOneWidget);
    expect(find.textContaining('API key'), findsNothing);                     // never in onboarding
    await tester.enterText(find.byKey(const ValueKey('onb-name')), 'Prince');
    await tester.pump();
    await tapText(tester, 'Next');
    expect(find.text('Nice to meet you, Prince! What would you like to call me?'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('onb-assistant')), 'Jarvis');
    await tester.pump();
    await tapText(tester, 'Next');

    // 1. Reel counter: prominent disclosure, Agree opens Accessibility settings
    expect(find.text('Reel counter'), findsOneWidget);
    expect(find.text('Never reads your messages or passwords'), findsOneWidget);
    expect(find.text('Count Reels and Shorts. Never reads messages or what you type.'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('allow-counter')));
    await tester.tap(find.byKey(const ValueKey('allow-counter')));
    await tester.pump();
    expect(core.named('openRealCountSettings'), hasLength(1));
    // back from Settings with it on: the card refreshes on resume
    core.status = {'realcount': true};
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(find.text('All set'), findsOneWidget);
    await tapText(tester, 'Continue');

    expect(find.text('Chip by the camera'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('allow-overlay')));
    await tester.tap(find.byKey(const ValueKey('allow-overlay')));
    await tester.pump();
    expect(core.named('openOverlaySettings'), hasLength(1));
    await skipCard(tester);
    expect(find.text('Screen time'), findsOneWidget);
    await skipCard(tester);
    expect(find.text('“Hey Jarvis” and buttons'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('mode-wake')));
    await tester.tap(find.byKey(const ValueKey('mode-wake')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('allow-mic')));
    await tester.tap(find.byKey(const ValueKey('allow-mic')));
    await tester.pump();
    expect((core.named('requestPermission').single.arguments as Map)['which'], 'microphone');
    await skipCard(tester);
    expect(find.text('Notifications'), findsOneWidget);
    await skipCard(tester);

    expect(find.text('You’re all set, Prince!'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('onb-go')));
    await tester.pump();
    await tester.pump();
    expect(core.args('setProfile'), {'name': 'Prince', 'assistant_name': 'Jarvis'});
    expect(core.named('setActivationMode').map((c) => (c.arguments as Map)['mode']), containsAll(['wake', 'volume', 'power']));
    expect(core.named('setActivationMode').firstWhere((c) => (c.arguments as Map)['mode'] == 'wake').arguments['on'], isTrue);
    final prefs = core.named('setRcPrefs').map((c) => '${(c.arguments as Map)['json']}').join();
    expect(prefs, contains('"onboarding_done":true'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(MainScaffold), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('onboarding: skipping the name and every card still finishes', (tester) async {
    tall(tester);
    await tester.pumpWidget(app(const OnboardingFlow()));
    await tester.pump();
    await tapText(tester, 'Skip');
    expect(find.text('Nice to meet you! What would you like to call me?'), findsOneWidget);
    await tapText(tester, 'Next');
    for (final title in ['Reel counter', 'Chip by the camera', 'Screen time', '“Hey Snapy” and buttons', 'Notifications']) {
      expect(find.text(title), findsOneWidget, reason: title);
      await skipCard(tester);
    }
    expect(find.text('You’re all set!'), findsOneWidget);
    expect(core.named('openRealCountSettings'), isEmpty);
    expect(core.named('requestPermission'), isEmpty);
    await tester.tap(find.byKey(const ValueKey('onb-go')));
    await tester.pump();
    await tester.pump();
    expect(core.args('setProfile')['assistant_name'], 'Snapy');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('onboarding: Xiaomi note, and the sideload unlock guide before Accessibility', (tester) async {
    tall(tester);
    core.device = {'manufacturer': 'Xiaomi', 'brand': 'Redmi', 'sdk': 34};
    core.restricted = true;
    await tester.pumpWidget(app(const OnboardingFlow(isInitialSetup: false)));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Xiaomi / HyperOS', skipOffstage: false), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('allow-counter')));
    await tester.tap(find.byKey(const ValueKey('allow-counter')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('One quick unlock first'), findsOneWidget);
    expect(core.named('openRealCountSettings'), isEmpty);
  });

  test('OEM detection for the how-to notes', () {
    expect(onboardingOem({'manufacturer': 'Nothing', 'brand': 'Nothing'}), 'nothing');
    expect(onboardingOem({'manufacturer': 'realme', 'brand': 'realme'}), 'oppo');
    expect(oemNoteKey('counter', 'samsung', 34), 'onb.oem.samsung_counter');
    expect(oemNoteKey('counter', 'other', 34), 'onb.oem.generic_counter');
    expect(oemNoteKey('counter', 'other', 30), isNull);
    expect(oemNoteKey('overlay', 'xiaomi', 34), 'onb.oem.xiaomi_overlay');
    expect(oemNoteKey('usage', 'xiaomi', 34), isNull);
  });

  // ------------------------------------------------------------------ profile

  testWidgets('profile rename saves both names and updates the screen', (tester) async {
    await tester.pumpWidget(app(const ProfileTab()));
    await tester.pump();
    await tester.tap(find.byTooltip('Edit names'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byKey(const ValueKey('profile-name')), 'Asha');
    await tester.enterText(find.byKey(const ValueKey('profile-assistant')), 'Nova');
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(core.args('setProfile'), {'name': 'Asha', 'assistant_name': 'Nova'});
    expect(ProfileStore.current.name, 'Asha');
    expect(find.text('Asha', skipOffstage: false), findsWidgets);
    expect(find.text('Wake word “Hey Nova”', skipOffstage: false), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  // ------------------------------------------------------------------ vault

  testWidgets('vault: Markdown view, export, clear only after confirming', (tester) async {
    tall(tester);
    core.vault = [
      {'id': 'm1', 'title': 'Standup', 'markdown': '# Standup\n- [x] ship it\n**Decision:** Friday'},
    ];
    await tester.pumpWidget(app(const VaultPage(initialKind: 'meetings')));
    await tester.pump();
    expect(core.args('vaultList')['kind'], 'meetings');
    await tester.tap(find.text('Standup'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('ship it'), findsOneWidget);
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(VaultItemPage), findsNothing);

    await tester.tap(find.byTooltip('Export'));
    await tester.pump();
    expect(find.text('Exported to /data/snapy/vault/meetings.md'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Clear Meetings?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(core.named('vaultClear'), isEmpty);

    await tester.tap(find.byTooltip('Clear'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
    await tester.pump();
    await tester.pump();
    expect(core.args('vaultClear')['kind'], 'meetings');
    expect(find.text('Nothing here yet.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });
}
