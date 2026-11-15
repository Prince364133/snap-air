import 'dart:async';

import 'package:flutter/material.dart';

import '../core/next_api.dart';
import '../core/snapy_core.dart';
import '../core/theme.dart';
import '../i18n/i18n.dart';
import '../sync/pair_screen.dart';
import 'battery_guide.dart';
import 'chip_settings.dart';
import 'common.dart';
import 'onboarding.dart';
import 'privacy_page.dart';

/// Where "Get a new key" goes for Gemini (the plan's copy table).
const geminiKeyUrl = 'https://aistudio.google.com/apikey';
const geminiRegionsUrl = 'https://ai.google.dev/gemini-api/docs/available-regions';

/// The exact message for a key test (docs/ANDROID_NEXT_PLAN.md §1 table).
String keyMessage(KeyVerdict v) => tr(switch (v) {
      KeyVerdict.ok => 'key.ok',
      KeyVerdict.invalid => 'key.invalid',
      KeyVerdict.permission => 'key.permission',
      KeyVerdict.quota => 'key.quota',
      KeyVerdict.region => 'key.region',
      KeyVerdict.network => 'key.network',
      KeyVerdict.error => 'key.error',
    });

/// Profile → Settings: AI brain (mode, provider, key with Test), voice, chip & big text,
/// permissions, battery, privacy, laptop and your data.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with WidgetsBindingObserver {
  Map<String, dynamic> _brain = const {};
  Map<String, bool> _perm = const {};
  String _provider = 'gemini';
  final _key = TextEditingController();
  bool _saving = false, _testing = false;
  String _voiceLang = 'auto';
  String? _wakeProgress;
  KeyVerdict? _verdict;
  String? _keyNote;          // "paste a key first" / "saved"
  String? _helpUrl;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    // "Hey Snapy" model download progress (once)
    _sub = SnapyCore.events.listen((e) {
      if (e['type'] != 'setup' || !mounted) return;
      final it = ((e['items'] as List?) ?? const []).whereType<Map>().firstWhere((i) => i['id'] == 'wake', orElse: () => const {});
      if (it.isEmpty) return;
      final total = (it['total'] as num?)?.toInt() ?? 0, done = (it['done'] as num?)?.toInt() ?? 0;
      setState(() => _wakeProgress = it['state'] == 'done' ? null : tr('settings.wake_downloading', {'pct': '${total > 0 ? (done * 100 ~/ total) : 0}'}));
    }, onError: (_) {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _key.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _load(); // back from Android Settings
  }

  Future<void> _load() async {
    try {
      final b = await SnapyCore.brainStatus();
      if (mounted) {
        setState(() {
          _brain = b;
          _provider = '${b['provider'] ?? 'gemini'}';
          _voiceLang = '${b['voice_language'] ?? 'auto'}';
        });
      }
    } catch (_) {}
    try {
      final p = await SnapyCore.status();
      if (mounted) setState(() => _perm = p);
    } catch (_) {}
  }

  Future<void> _test() async {
    final key = _key.text.trim();
    if (key.isEmpty) {
      setState(() { _verdict = null; _keyNote = tr('key.empty'); });
      return;
    }
    setState(() { _testing = true; _verdict = null; _keyNote = tr('key.testing'); });
    final r = await NextApi.testApiKey(_provider, key);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _keyNote = null;
      _verdict = r.verdict;
      _helpUrl = r.helpUrl;
    });
  }

  Future<void> _save() async {
    final key = _key.text.trim();
    if (key.isEmpty) {
      setState(() { _verdict = null; _keyNote = tr('key.empty'); });
      return;
    }
    setState(() => _saving = true);
    try {
      final b = await SnapyCore.setApiKey(_provider, key);
      _key.clear();
      if (mounted) setState(() { _brain = b; _keyNote = tr('settings.key_saved'); });
    } catch (_) {
      if (mounted) setState(() => _keyNote = tr('profile.unavailable'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _update(Map<String, dynamic> changes) async {
    try {
      await SnapyCore.updateSettings(changes);
    } catch (_) {}
    _load();
  }

  Future<void> _grant(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {}
    _load();
  }

  Future<void> _deleteAll() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('settings.delete_title')),
        content: Text(tr('settings.delete_body')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: SnapyColors.of(ctx).red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('settings.delete_all')),
          ),
        ],
      ),
    );
    if (yes != true) return;
    final ok = await NextApi.vaultClear('all');
    if (mounted) toast(context, ok ? tr('settings.deleted') : tr('vault.clear_failed'));
  }

  Widget _keyResult(SnapyColors c) {
    final v = _verdict;
    if (v == null) {
      if (_keyNote == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Semantics(liveRegion: true, child: Text(_keyNote!, style: Theme.of(context).textTheme.bodySmall)),
      );
    }
    final ok = v == KeyVerdict.ok;
    final color = ok ? c.green : (v == KeyVerdict.network ? c.orange : c.red);
    final newKeyUrl = _provider == 'gemini' ? geminiKeyUrl : (_helpUrl ?? geminiKeyUrl);
    Widget? action;
    switch (v) {
      case KeyVerdict.ok:
        action = null;
      case KeyVerdict.region:
        action = TextButton.icon(onPressed: () => openLink(context, geminiRegionsUrl), icon: const Icon(Icons.help_outline), label: Text(tr('key.help')));
      case KeyVerdict.network:
        action = TextButton.icon(onPressed: _test, icon: const Icon(Icons.refresh), label: Text(tr('key.retry')));
      default:
        action = TextButton.icon(onPressed: () => openLink(context, newKeyUrl), icon: const Icon(Icons.open_in_new), label: Text(tr('key.get_new')));
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(r),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Semantics(
          liveRegion: true,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(ok ? Icons.check_circle : Icons.error_outline, color: color, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(keyMessage(v), style: const TextStyle(fontWeight: FontWeight.w500)))),
          ]),
        ),
        if (action != null) Align(alignment: Alignment.centerRight, child: action),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final providers = {
      'gemini': 'Google Gemini (Flash 2.5)',
      'openai': 'OpenAI (GPT-4o)',
      'anthropic': 'Anthropic (Claude 3.5)',
    };
    final isConnected = _brain['cloud_configured'] == true;

    Widget group(String title, List<Widget> children) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Semantics(header: true, child: Text(title, style: Theme.of(context).textTheme.bodySmall)),
            ),
            Material(
              color: c.card,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLg), side: BorderSide(color: c.hair)),
              child: Column(children: children),
            ),
          ]),
        );
    Widget nav(String title, IconData icon, Widget page) => ListTile(
          leading: Icon(icon),
          title: Text(title),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)).then((_) => _load()),
        );
    Widget perm(String title, String key, Future<void> Function() grant) {
      final on = _perm[key] ?? false;
      return ListTile(
        leading: Icon(on ? Icons.check_circle : Icons.radio_button_unchecked, color: on ? c.green : c.text3),
        title: Text(title),
        subtitle: Text(on ? tr('common.on') : tr('common.off')),
        trailing: on ? null : const Icon(Icons.chevron_right),
        onTap: on ? null : () => _grant(grant),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(tr('settings.title')), backgroundColor: c.bg),
      body: ListView(children: [
        group('AI Brain Intelligence', [
          // Connection Status Banner
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isConnected ? c.green.withValues(alpha: 0.12) : c.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: (isConnected ? c.green : c.orange).withValues(alpha: 0.35)),
            ),
            child: Row(
              children: [
                Icon(isConnected ? Icons.check_circle_rounded : Icons.warning_amber_rounded, color: isConnected ? c.green : c.orange, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isConnected ? 'Connected to ${providers[_brain['provider']] ?? _brain['provider']}' : 'Your API is not connected till now',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: c.text),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isConnected ? 'Cloud brain is active for speech and conscious answers.' : 'Add your API key below to enable intelligent speech and AI answers.',
                        style: TextStyle(color: c.text2, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              DropdownButtonFormField<String>(
                initialValue: providers.containsKey(_provider) ? _provider : 'gemini',
                items: providers.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                onChanged: (v) => setState(() { _provider = v ?? _provider; _verdict = null; }),
                decoration: const InputDecoration(labelText: 'AI Provider'),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('api-key'),
                controller: _key,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Provider API Key',
                  hintText: 'Paste ${_provider == "gemini" ? "AIzaSy..." : "sk-..."}',
                ),
              ),
              _keyResult(c),
              const SizedBox(height: 14),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                OutlinedButton.icon(
                  onPressed: _testing ? null : _test,
                  icon: _testing
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.network_check, size: 18),
                  label: const Text('Test Connection'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.lock_outline, size: 18),
                  label: const Text('Save API Key'),
                  style: FilledButton.styleFrom(
                    backgroundColor: c.accent,
                    minimumSize: const Size(48, 48),
                  ),
                ),
              ]),
            ]),
          ),
        ]),
        group(tr('settings.voice'), [
          SwitchListTile(
            title: Text(tr('settings.wake')),
            subtitle: Text(_wakeProgress ?? tr('permission.mic.body')),
            value: _perm['wake'] ?? false,
            onChanged: (on) async {
              var ok = false;
              try {
                ok = await SnapyCore.setWakeWord(on);
              } catch (_) {}
              if (!ok && on && context.mounted) toast(context, tr('settings.wake_mic_denied'));
              _load();
            },
          ),
          ListTile(
            title: const Text('Spoken Language'),
            trailing: DropdownButton<String>(
              value: _voiceLang,
              underline: const SizedBox(),
              items: const [
                DropdownMenuItem(value: 'auto', child: Text('Auto (Follow Phone)')),
                DropdownMenuItem(value: 'en-US', child: Text('English (US)')),
                DropdownMenuItem(value: 'en-IN', child: Text('English (India)')),
                DropdownMenuItem(value: 'es', child: Text('Español (Spanish)')),
                DropdownMenuItem(value: 'fr', child: Text('Français (French)')),
                DropdownMenuItem(value: 'de', child: Text('Deutsch (German)')),
                DropdownMenuItem(value: 'ja', child: Text('日本語 (Japanese)')),
                DropdownMenuItem(value: 'zh', child: Text('中文 (Chinese)')),
                DropdownMenuItem(value: 'ar', child: Text('العربية (Arabic)')),
                DropdownMenuItem(value: 'pt', child: Text('Português (Portuguese)')),
                DropdownMenuItem(value: 'it', child: Text('Italiano (Italian)')),
                DropdownMenuItem(value: 'ko', child: Text('한국어 (Korean)')),
                DropdownMenuItem(value: 'ru', child: Text('Русский (Russian)')),
                DropdownMenuItem(value: 'hi', child: Text('हिन्दी (Hindi)')),
                DropdownMenuItem(value: 'mr', child: Text('मराठी (Marathi)')),
                DropdownMenuItem(value: 'bn', child: Text('বাংলা (Bengali)')),
                DropdownMenuItem(value: 'te', child: Text('తెలుగు (Telugu)')),
                DropdownMenuItem(value: 'ta', child: Text('தமிழ் (Tamil)')),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _voiceLang = v);
                _update({'voice_language': v});
              },
            ),
          ),
        ]),
        group('Camera Halo & Capsule HUD', [
          nav(tr('rcset.title'), Icons.tune, const ChipSettingsPage()),
        ]),
        group(tr('settings.permissions'), [
          perm(tr('settings.counter'), 'realcount', SnapyCore.openRealCountSettings),
          perm(tr('settings.overlay'), 'overlay', SnapyCore.openOverlaySettings),
          perm(tr('settings.usage_access'), 'usage', SnapyCore.openUsageAccess),
          perm(tr('settings.mic'), 'microphone', () => SnapyCore.requestPermission('microphone')),
          perm(tr('settings.notifications'), 'notifications', SnapyCore.requestNotifications),
          perm(tr('settings.contacts'), 'contacts', () => SnapyCore.requestPermission('contacts')),
          perm(tr('settings.calls'), 'calls', () => SnapyCore.requestPermission('calls')),
          nav(tr('settings.perm_guide'), Icons.verified_user_outlined, const OnboardingFlow(isInitialSetup: false)),
          nav(tr('rcset.battery'), Icons.battery_charging_full_outlined, const BatteryGuidePage()),
        ]),
        group(tr('settings.laptop'), [
          nav(tr('tools.pair_title'), Icons.laptop, const PairLaptopPage()),
        ]),
        group(tr('settings.data'), [
          nav(tr('rcset.privacy'), Icons.receipt_long_outlined, const PrivacyReceiptsPage()),
          ListTile(
            leading: const Icon(Icons.ios_share),
            title: Text(tr('settings.export')),
            onTap: () async {
              final path = await NextApi.vaultExport('all');
              if (context.mounted) toast(context, path == null ? tr('settings.export_failed') : tr('settings.export_done', {'path': path}));
            },
          ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: c.red),
            title: Text(tr('settings.delete_all'), style: TextStyle(color: c.red)),
            onTap: _deleteAll,
          ),
        ]),
        const SizedBox(height: 24),
      ]),
    );
  }
}
