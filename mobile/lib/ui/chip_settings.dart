import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import '../core/snapy_core.dart';
import '../core/theme.dart';
import '../i18n/i18n.dart';
import '../main.dart';
import '../realcount/nudges.dart' show dayKey;
import '../realcount/realcount_data.dart';
import '../realcount/rules.dart';
import 'battery_guide.dart';
import 'onboarding.dart';
import 'privacy_page.dart';
import 'report_page.dart';

/// Real Count settings: the chip (show, size, position, hide), nudges, intention prompt,
/// creator mode, the opt-in pause, soft limits, bedtime, simple mode and language.
class ChipSettingsPage extends StatefulWidget {
  const ChipSettingsPage({super.key});
  @override
  State<ChipSettingsPage> createState() => _ChipSettingsPageState();
}

class _ChipSettingsPageState extends State<ChipSettingsPage> {
  RcPrefs _p = RcPrefs(const {});
  RealCountRules _rules = RealCountRules.fallback;
  Map<String, int> _limits = const {};
  bool _break = false;
  Map<String, String> _social = const {};       // package -> label (short-video apps first)

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await RealCountRepo.prefs();
    final rules = await RealCountRepo.rules();
    final l = await RealCountRepo.limits();
    Map<String, String> social = const {};
    try {
      final apps = await SnapyCore.config('android.social_apps');
      if (apps is List) {
        social = {for (final a in apps) if (a is Map) '${a['package']}': '${a['label']}'};
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _p = p;
        _rules = rules;
        _limits = l.limits;
        _break = l.breakScreen;
        _social = social;
      });
    }
  }

  Future<void> _set(String k, dynamic v) async {
    setState(() => _p = RcPrefs({..._p.v, k: v}));
    await RealCountRepo.setPrefs({k: v});
    if (k == 'simple_mode') SnapyApp.simple.value = v == true;
    if (k == 'ui_lang') await I18n.use(I18n.resolve('$v', PlatformDispatcher.instance.locale.languageCode));
    if (k == 'chip_enabled' || k == 'overlay_fallback') await SnapyCore.startChip().catchError((_) => false);
  }

  Future<int?> _pickNumber(String title, List<int> options, int current, String Function(int) label) => showModalBottomSheet<int>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(shrinkWrap: true, children: [
            ListTile(title: Text(title, style: Theme.of(ctx).textTheme.titleMedium)),
            for (final o in options)
              ListTile(
                title: Text(label(o)),
                trailing: o == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(ctx, o),
              ),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final simple = _p.b('simple_mode');
    Widget group(String title, List<Widget> children) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(left: 4, bottom: 8), child: Text(title, style: Theme.of(context).textTheme.bodySmall)),
            Material(
              color: c.card,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLg), side: BorderSide(color: c.hair)),
              child: Column(children: children),
            ),
          ]),
        );
    Widget sw(String k, String title, [String? sub]) => SwitchListTile(
          title: Text(title),
          subtitle: sub == null ? null : Text(sub),
          value: _p.b(k),
          onChanged: (v) => _set(k, v),
        );
    String mins(int m) => m == 0 ? tr('rcset.none') : tr('rcset.minutes', {'min': '$m'});
    final hiddenToday = _p.s('hidden_day') == _today();
    final custom = _p.i('chip_x') >= 0;

    return Scaffold(
      appBar: AppBar(title: Text(tr('rcset.title')), backgroundColor: c.bg),
      body: ListView(children: [
        group(tr('home.real_count'), [
          sw('chip_enabled', tr('rcset.chip'), tr('rcset.chip_sub')),
          ListTile(
            title: Text(tr('rcset.size')),
            trailing: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [for (final s in ['small', 'normal', 'large']) ButtonSegment(value: s, label: Text(tr('size.$s')))],
              selected: {_p.s('chip_size')},
              onSelectionChanged: (v) => _set('chip_size', v.first),
            ),
          ),
          ListTile(
            title: Text(tr('rcset.position')),
            subtitle: Text(custom ? tr('rcset.position_custom') : tr('rcset.position_auto')),
            trailing: custom ? TextButton(onPressed: () async { await _set('chip_x', -1); await _set('chip_y', -1); }, child: Text(tr('rcset.reset_position'))) : null,
          ),
          ListTile(
            title: Text(hiddenToday ? tr('rcset.hidden_today') : tr('rcset.hide_today')),
            trailing: TextButton(
              onPressed: () => _set('hidden_day', hiddenToday ? '' : _today()),
              child: Text(hiddenToday ? tr('rcset.show_again') : tr('rcset.hide_today')),
            ),
          ),
          if (!simple) sw('overlay_fallback', tr('rcset.overlay_fallback'), tr('rcset.overlay_fallback_sub')),
        ]),
        group(tr('rcset.nudges'), [
          sw('nudges', tr('rcset.nudges'), tr('rcset.nudges_sub', {'min': '${_rules.i('nudges.min_gap_min')}'})),
          sw('intention_prompt', tr('rcset.intention'), tr('rcset.intention_sub')),
          if (!simple) sw('speak_nudges', tr('rcset.speak')),
          SwitchListTile(
            title: Text(tr('rcset.break')),
            subtitle: Text(tr('rcset.break_sub')),
            value: _break,
            onChanged: (v) async {
              setState(() => _break = v);
              await RealCountRepo.setBreakScreen(v);
            },
          ),
          ListTile(
            title: Text(tr('rcset.reel_limit')),
            trailing: Text(_p.i('reel_limit') == 0 ? tr('rcset.none') : tr('rcset.reels_n', {'n': '${_p.i('reel_limit')}'})),
            onTap: () async {
              final v = await _pickNumber(tr('rcset.reel_limit'), const [0, 20, 30, 50, 80, 120], _p.i('reel_limit'),
                  (n) => n == 0 ? tr('rcset.none') : tr('rcset.reels_n', {'n': '$n'}));
              if (v != null) await _set('reel_limit', v);
            },
          ),
          ListTile(
            title: Text(tr('rcset.bedtime')),
            trailing: Text(_p.s('bedtime').isEmpty ? _rules.s('nudges.bedtime') : _p.s('bedtime')),
            onTap: () async {
              final cur = parseHm(_p.s('bedtime').isEmpty ? _rules.s('nudges.bedtime') : _p.s('bedtime'));
              final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: cur ~/ 60, minute: cur % 60));
              if (t != null) await _set('bedtime', '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}');
            },
          ),
          if (!simple) sw('creator_mode', tr('rcset.creator'), tr('rcset.creator_sub')),
        ]),
        if (!simple && _social.isNotEmpty)
          group(tr('rcset.app_limits'), [
            for (final e in _social.entries.take(12))
              ListTile(
                dense: true,
                title: Text(e.value),
                trailing: Text(mins(_limits[e.key] ?? 0)),
                onTap: () async {
                  final v = await _pickNumber(e.value, const [0, 15, 30, 45, 60, 90, 120], _limits[e.key] ?? 0, mins);
                  if (v == null) return;
                  await RealCountRepo.setLimit(e.key, v);
                  _load();
                },
              ),
          ]),
        group(tr('rcset.more'), [
          sw('simple_mode', tr('rcset.simple'), tr('rcset.simple_sub')),
          ListTile(
            title: Text(tr('rcset.language')),
            trailing: DropdownButton<String>(
              value: _p.s('ui_lang'),
              underline: const SizedBox(),
              items: [
                DropdownMenuItem(value: 'auto', child: Text(tr('rcset.lang_auto'))),
                const DropdownMenuItem(value: 'en', child: Text('English')),
                const DropdownMenuItem(value: 'hi', child: Text('हिन्दी')),
                const DropdownMenuItem(value: 'ta', child: Text('தமிழ்')),
                const DropdownMenuItem(value: 'te', child: Text('తెలుగు')),
                const DropdownMenuItem(value: 'mr', child: Text('मराठी')),
                const DropdownMenuItem(value: 'bn', child: Text('বাংলা')),
              ],
              onChanged: (v) => v == null ? null : _set('ui_lang', v),
            ),
          ),
          _nav(tr('rc.report'), Icons.insights_outlined, const ReportPage()),
          _nav(tr('rcset.battery'), Icons.battery_charging_full_outlined, const BatteryGuidePage()),
          _nav(tr('rcset.privacy'), Icons.receipt_long_outlined, const PrivacyReceiptsPage()),
          _nav(tr('rcset.permissions'), Icons.verified_user_outlined, const PermissionFlow()),
          if (!simple) sw('counter_reports', tr('rcset.reports'), tr('rcset.reports_sub')),
        ]),
        const SizedBox(height: 24),
      ]),
    );
  }

  Widget _nav(String title, IconData icon, Widget page) => ListTile(
        leading: Icon(icon),
        title: Text(title),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)),
      );

  static String _today() => dayKey(DateTime.now());
}
