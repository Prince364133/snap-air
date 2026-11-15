import 'dart:async';

import 'package:flutter/material.dart';

import '../core/snapy_core.dart';
import '../core/theme.dart';
import '../i18n/i18n.dart';
import 'battery_guide.dart';
import 'chip_settings.dart';
import 'onboarding.dart';
import 'privacy_page.dart';

/// AI brain (same three modes as Windows: on this phone / auto / cloud) and permissions.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Map<String, dynamic> _brain = const {};
  Map<String, bool> _perm = const {};
  String _provider = 'gemini';
  final _key = TextEditingController();
  bool _saving = false;
  String _voiceLang = 'auto';
  String? _wakeProgress;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    // "Hey Snapy" model download progress (36 MB, once)
    _sub = SnapyCore.events.listen((e) {
      if (e['type'] != 'setup' || !mounted) return;
      final it = ((e['items'] as List?) ?? const []).cast<Map>().firstWhere((i) => i['id'] == 'wake', orElse: () => const {});
      if (it.isEmpty) return;
      final total = (it['total'] as num?)?.toInt() ?? 0, done = (it['done'] as num?)?.toInt() ?? 0;
      setState(() => _wakeProgress = it['state'] == 'done' ? null : 'Downloading “Hey Snapy” model… ${total > 0 ? (done * 100 ~/ total) : 0}%');
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final b = await SnapyCore.brainStatus();
      final p = await SnapyCore.status();
      if (mounted) setState(() { _brain = b; _perm = p; _provider = (b['provider'] ?? 'gemini') as String; _voiceLang = (b['voice_language'] ?? 'auto') as String; });
    } catch (_) {}
  }

  Future<void> _saveKey() async {
    setState(() => _saving = true);
    try {
      final b = await SnapyCore.setApiKey(_provider, _key.text.trim());
      _key.clear();
      if (mounted) {
        setState(() => _brain = b);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Key saved — encrypted on this phone')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final providers = Map<String, String>.from((_brain['providers'] as Map?) ?? {'gemini': 'Google Gemini', 'openai': 'OpenAI'});
    final mode = (_brain['mode'] ?? 'auto') as String;
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
    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), backgroundColor: c.bg),
      body: ListView(children: [
        group('AI brain', [
          RadioGroup<String>(
            groupValue: mode,
            onChanged: (v) async {
              if (v == null) return;
              await SnapyCore.updateSettings({'ai_provider': v});
              _load();
            },
            child: const Column(children: [
              RadioListTile(value: 'local', title: Text('On this phone'), subtitle: Text('Private and offline (on-device model arrives in the next update)')),
              RadioListTile(value: 'auto', title: Text('Auto'), subtitle: Text('On this phone when possible, cloud when faster')),
              RadioListTile(value: 'cloud', title: Text('Cloud'), subtitle: Text('Your own Gemini or OpenAI key')),
            ]),
          ),
          ListTile(
            title: const Text('Status'),
            subtitle: Text((_brain['cloud_configured'] == true)
                ? 'Cloud key saved (${providers[_brain['provider']] ?? _brain['provider']})'
                : 'No AI key yet — commands, reminders and memory still work'),
          ),
          if (_brain['error'] != null) ListTile(title: Text('${_brain['error']}', style: TextStyle(color: c.red))),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(children: [
              DropdownButtonFormField<String>(
                initialValue: providers.containsKey(_provider) ? _provider : providers.keys.first,
                items: providers.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                onChanged: (v) => setState(() => _provider = v ?? _provider),
                decoration: const InputDecoration(labelText: 'Provider'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _key,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'API key', hintText: 'Paste your key — stored encrypted on this phone'),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(onPressed: _saving ? null : _saveKey, child: const Text('Save key')),
              ),
            ]),
          ),
        ]),
        group('Voice', [
          SwitchListTile(
            title: const Text('“Hey Snapy”'),
            subtitle: Text(_wakeProgress ??
                'Say its name any time, even in other apps. Listens on your phone only; shows a small notification while on.'),
            value: _perm['wake'] ?? false,
            onChanged: (on) async {
              final ok = await SnapyCore.setWakeWord(on);
              if (!ok && on && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Allow the microphone, then turn this on again.')));
              }
              _load();
            },
          ),
          ListTile(
            title: const Text('Language I speak'),
            trailing: DropdownButton<String>(
              value: _voiceLang,
              underline: const SizedBox(),
              items: const [
                DropdownMenuItem(value: 'auto', child: Text('English / Hinglish')),
                DropdownMenuItem(value: 'hi', child: Text('हिन्दी (Hindi)')),
                DropdownMenuItem(value: 'mr', child: Text('मराठी (Marathi)')),
                DropdownMenuItem(value: 'bn', child: Text('বাংলা (Bengali)')),
                DropdownMenuItem(value: 'te', child: Text('తెలుగు (Telugu)')),
                DropdownMenuItem(value: 'ta', child: Text('தமிழ் (Tamil)')),
              ],
              onChanged: (v) async {
                if (v == null) return;
                setState(() => _voiceLang = v);
                await SnapyCore.updateSettings({'voice_language': v});
              },
            ),
          ),
        ]),
        group('Permissions', [
          SwitchListTile(
            title: const Text('Contacts'),
            subtitle: const Text('For “call Mom” and “WhatsApp Rahul …”. Read on your phone only.'),
            value: _perm['contacts'] ?? false,
            onChanged: (_) async { await SnapyCore.requestPermission('contacts'); _load(); },
          ),
          SwitchListTile(
            title: const Text('Place calls directly'),
            subtitle: const Text('Otherwise Snapy opens the dialler with the number ready.'),
            value: _perm['calls'] ?? false,
            onChanged: (_) async { await SnapyCore.requestPermission('calls'); _load(); },
          ),
          SwitchListTile(
            title: const Text('Reminder notifications'),
            value: _perm['notifications'] ?? false,
            onChanged: (_) async { await SnapyCore.requestNotifications(); _load(); },
          ),
          ListTile(
            title: const Text('Real Count'),
            subtitle: Text((_perm['realcount'] ?? false) ? 'On' : 'Off'),
            trailing: const Icon(Icons.chevron_right),
            onTap: SnapyCore.openRealCountSettings,
          ),
          ListTile(
            title: const Text('Usage access'),
            subtitle: Text((_perm['usage'] ?? false) ? 'On' : 'Off'),
            trailing: const Icon(Icons.chevron_right),
            onTap: SnapyCore.openUsageAccess,
          ),
          ListTile(
            title: Text(tr('perm.overlay.title')),
            subtitle: Text((_perm['overlay'] ?? false) ? tr('common.on') : tr('common.off')),
            trailing: const Icon(Icons.chevron_right),
            onTap: SnapyCore.openOverlaySettings,
          ),
          ListTile(
            title: Text(tr('rcset.permissions')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PermissionFlow())).then((_) => _load()),
          ),
        ]),
        group(tr('home.real_count'), [
          ListTile(
            title: Text(tr('rcset.title')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ChipSettingsPage())),
          ),
          ListTile(
            title: Text(tr('rcset.battery')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BatteryGuidePage())),
          ),
          ListTile(
            title: Text(tr('rcset.privacy')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PrivacyReceiptsPage())),
          ),
        ]),
        const SizedBox(height: 24),
      ]),
    );
  }
}
