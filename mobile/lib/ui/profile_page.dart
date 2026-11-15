import 'package:flutter/material.dart';

import '../core/snapy_core.dart';
import '../core/theme.dart';
import 'privacy_page.dart';
import 'settings_page.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  String _userName = 'Boss';
  String _aiName = 'Snapy';
  bool _wakeWord = true;
  bool _volumeKeys = true;
  bool _cameraTap = true;
  Map<String, dynamic> _device = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await SnapyCore.rcPrefs();
      final dev = await SnapyCore.device();
      if (mounted) {
        setState(() {
          _userName = (p['user_name'] as String?)?.isNotEmpty == true ? p['user_name'] as String : 'Boss';
          _aiName = (p['ai_name'] as String?)?.isNotEmpty == true ? p['ai_name'] as String : 'Snapy';
          _wakeWord = p['wake_enabled'] as bool? ?? true;
          _volumeKeys = p['volume_shortcut'] as bool? ?? true;
          _cameraTap = p['camera_tap'] as bool? ?? true;
          _device = dev;
        });
      }
    } catch (_) {}
  }

  Future<void> _editNames() async {
    final userCtrl = TextEditingController(text: _userName);
    final aiCtrl = TextEditingController(text: _aiName);

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Personalize Your AI'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: userCtrl,
              decoration: const InputDecoration(labelText: 'What should Snapy call you?', hintText: 'e.g. Prince'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: aiCtrl,
              decoration: const InputDecoration(labelText: 'Name your AI Assistant', hintText: 'e.g. Snapy or Jarvis'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final newU = userCtrl.text.trim();
              final newA = aiCtrl.text.trim();
              if (newU.isNotEmpty) _userName = newU;
              if (newA.isNotEmpty) _aiName = newA;
              await SnapyCore.setRcPrefs({'user_name': _userName, 'ai_name': _aiName});
              if (mounted) setState(() {});
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile & Identity'),
        backgroundColor: c.bg,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () {
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage())).then((_) => _load());
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          // 1. User Identity Card
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: c.hair)),
            color: c.card,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 32,
                    backgroundColor: c.accent.withValues(alpha: 0.2),
                    child: Text(
                      _userName.isNotEmpty ? _userName[0].toUpperCase() : 'B',
                      style: TextStyle(color: c.accent, fontSize: 28, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_userName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
                        const SizedBox(height: 4),
                        Text('AI Companion: $_aiName', style: TextStyle(color: c.accent, fontWeight: FontWeight.w600, fontSize: 14)),
                        const SizedBox(height: 4),
                        const Text('100% On-Device · Fully Private', style: TextStyle(color: Colors.grey, fontSize: 12)),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _editNames,
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: 'Edit Names',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 2. Universal Activation Shortcuts
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: c.hair)),
            color: c.card,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Activation Methods', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: Icon(Icons.mic, color: c.accent),
                    title: Text('Wake Word ("Hey $_aiName")'),
                    subtitle: Text('Responds: "Yes $_userName, tell me!" even on lock screen'),
                    value: _wakeWord,
                    onChanged: (v) async {
                      setState(() => _wakeWord = v);
                      await SnapyCore.setRcPrefs({'wake_enabled': v});
                      await SnapyCore.setWakeWord(v);
                    },
                  ),
                  const Divider(),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: Icon(Icons.volume_up, color: c.accent),
                    title: const Text('Hold Volume Up + Down for 3s'),
                    subtitle: const Text('Universal hardware shortcut — works when phone is locked or asleep'),
                    value: _volumeKeys,
                    onChanged: (v) async {
                      setState(() => _volumeKeys = v);
                      await SnapyCore.setRcPrefs({'volume_shortcut': v});
                    },
                  ),
                  const Divider(),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: Icon(Icons.camera_alt_outlined, color: c.accent),
                    title: const Text('Tap Camera Cutout Halo'),
                    subtitle: const Text('Drops status capsule and AI chat directly below the front camera'),
                    value: _cameraTap,
                    onChanged: (v) async {
                      setState(() => _cameraTap = v);
                      await SnapyCore.setRcPrefs({'camera_tap': v});
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 3. Settings & Conscious Memory Navigation
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: c.hair)),
            color: c.card,
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.vpn_key_outlined, color: c.accent),
                  title: const Text('AI Brain & Gemini API Key', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('Configure your key with live validation test'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage())).then((_) => _load());
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.memory, color: c.green),
                  title: const Text('Conscious Memory Vault', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('Inspect local memory notes and meeting minutes'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('All conscious memory files are stored in local Markdown on your device.')),
                    );
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.privacy_tip_outlined, color: c.accent),
                  title: const Text('Privacy & Security Report', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('Zero telemetry, on-device encryption guarantee'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PrivacyReceiptsPage()));
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 4. Device Footer Info
          if (_device.isNotEmpty)
            Center(
              child: Text(
                '${_device['manufacturer'] ?? ''} ${_device['model'] ?? ''} · Android SDK ${_device['sdk'] ?? ''} · Snapy v${_device['snapy_version'] ?? '2.0'}',
                style: const TextStyle(color: Colors.grey, fontSize: 11),
              ),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
