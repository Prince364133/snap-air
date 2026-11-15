import 'package:flutter/material.dart';

import '../core/next_api.dart';
import '../core/snapy_core.dart';
import '../core/theme.dart';
import '../i18n/i18n.dart';
import 'common.dart';
import 'privacy_page.dart';
import 'profile_store.dart';
import 'settings_page.dart';
import 'vault_page.dart';

/// Profile: who you are and what you call Snapy, how you wake it, Settings, the memory vault
/// and the emergency (ICE) notes shown on the SOS card.
class ProfileTab extends StatefulWidget {
  const ProfileTab({super.key});
  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
  ActivationModes _modes = const ActivationModes();
  final _ice = TextEditingController();
  Map<String, dynamic> _device = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ice.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final p = await ProfileStore.load();
    final m = await NextApi.activationModes();
    Map<String, dynamic> dev = const {};
    try {
      dev = await SnapyCore.device();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      if (_ice.text.isEmpty) _ice.text = p.iceNotes;
      if (m != null) _modes = m;
      _device = dev;
    });
  }

  Future<void> _editNames() async {
    final p = ProfileStore.current;
    final name = TextEditingController(text: p.name);
    final assistant = TextEditingController(text: p.assistantName);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('profile.edit')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            key: const ValueKey('profile-name'),
            controller: name,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: tr('profile.your_name'), hintText: tr('profile.name_hint')),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('profile-assistant'),
            controller: assistant,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: tr('profile.assistant_name'), hintText: tr('profile.assistant_hint')),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('common.save'))),
        ],
      ),
    );
    if (saved == true) {
      await ProfileStore.save(name: name.text.trim(), assistantName: assistant.text.trim().isEmpty ? 'Snapy' : assistant.text.trim());
      if (mounted) toast(context, tr('profile.saved'));
    }
    name.dispose();
    assistant.dispose();
  }

  Future<void> _setMode(String mode, bool on) async {
    setState(() => _modes = _modes.withMode(mode, on));
    final m = await NextApi.setActivationMode(mode, on);
    if (m != null && mounted) setState(() => _modes = m);
    if (mode == 'power' && on && !_modes.assistantRole) await _askRole();
  }

  Future<void> _askRole() async {
    final ok = await NextApi.requestAssistantRole();
    final m = await NextApi.activationModes();
    if (!mounted) return;
    setState(() => _modes = m ?? (ok ? ActivationModes(wake: _modes.wake, volume: _modes.volume, power: _modes.power, assistantRole: true) : _modes));
    if (!ok && m == null) toast(context, tr('profile.unavailable'));
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    return Scaffold(
      body: SafeArea(
        child: ValueListenableBuilder<SnapyProfile>(
          valueListenable: ProfileStore.notifier,
          builder: (context, p, _) {
            final a = {'assistant': p.assistantName};
            return ListView(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Semantics(header: true, child: Text(tr('profile.title'), style: Theme.of(context).textTheme.headlineMedium)),
              ),
              // identity
              SnapyCard(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
                  child: Row(children: [
                    ExcludeSemantics(
                      child: CircleAvatar(
                        radius: 30,
                        backgroundColor: c.accentSoft,
                        child: Text(p.name.isEmpty ? '?' : p.name.characters.first.toUpperCase(),
                            style: TextStyle(color: c.accent, fontSize: 26, fontWeight: FontWeight.w700)),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(p.name.isEmpty ? tr('profile.no_name') : p.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 20)),
                        const SizedBox(height: 2),
                        Text('${tr('profile.assistant_name')}: ${p.assistantName}', style: TextStyle(color: c.accent, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(tr('profile.private_line'), style: small),
                      ]),
                    ),
                    IconButton(tooltip: tr('profile.edit'), icon: const Icon(Icons.edit_outlined), onPressed: _editNames),
                  ]),
                ),
              ]),
              // activation
              SnapyCard(
                title: tr('profile.activation'),
                icon: Icons.touch_app_outlined,
                children: [
                  CheckboxListTile(
                    secondary: const Icon(Icons.record_voice_over_outlined),
                    title: Text(tr('profile.wake', a)),
                    subtitle: Text(tr('profile.wake_sub')),
                    value: _modes.wake,
                    onChanged: (v) => _setMode('wake', v ?? false),
                  ),
                  CheckboxListTile(
                    secondary: const Icon(Icons.volume_up_outlined),
                    title: const Text('Hold Volume Up + Down for 2s'),
                    subtitle: const Text('Instantly summons your AI from anywhere, even over full-screen apps.'),
                    value: _modes.volume,
                    onChanged: (v) => _setMode('volume', v ?? false),
                  ),
                  CheckboxListTile(
                    secondary: const Icon(Icons.power_settings_new),
                    title: Text(tr('profile.power')),
                    subtitle: Text(tr('profile.power_sub', a)),
                    value: _modes.power,
                    onChanged: (v) => _setMode('power', v ?? false),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    child: _modes.assistantRole
                        ? Row(children: [
                            Icon(Icons.check_circle, color: c.green, size: 20),
                            const SizedBox(width: 8),
                            Expanded(child: Text(tr('profile.assistant_role_on', a))),
                          ])
                        : OutlinedButton.icon(
                            onPressed: _askRole,
                            icon: const Icon(Icons.assistant_outlined),
                            label: Text(tr('profile.make_assistant', a)),
                            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                          ),
                  ),
                ],
              ),
              // settings, vault, privacy
              SnapyCard(children: [
                ListTile(
                  minTileHeight: 60,
                  leading: Icon(Icons.settings_outlined, color: c.accent),
                  title: Text(tr('profile.settings'), style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(tr('profile.settings_sub')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage())).then((_) => _load()),
                ),
                Divider(height: 1, color: c.hair),
                ListTile(
                  minTileHeight: 60,
                  leading: Icon(Icons.inventory_2_outlined, color: c.green),
                  title: Text(tr('profile.vault'), style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(tr('profile.vault_sub')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const VaultPage())),
                ),
                Divider(height: 1, color: c.hair),
                ListTile(
                  minTileHeight: 60,
                  leading: Icon(Icons.receipt_long_outlined, color: c.accent),
                  title: Text(tr('rcset.privacy'), style: const TextStyle(fontWeight: FontWeight.w600)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PrivacyReceiptsPage())),
                ),
              ]),
              // ICE
              SnapyCard(
                title: tr('profile.ice'),
                subtitle: tr('profile.ice_sub'),
                icon: Icons.medical_information_outlined,
                iconColor: c.red,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: TextField(
                      key: const ValueKey('ice-notes'),
                      controller: _ice,
                      minLines: 2,
                      maxLines: 5,
                      decoration: InputDecoration(hintText: tr('profile.ice_hint'), border: const OutlineInputBorder()),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.tonal(
                        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: () async {
                          await ProfileStore.save(iceNotes: _ice.text.trim());
                          if (context.mounted) toast(context, tr('profile.saved'));
                        },
                        child: Text(tr('profile.ice_save')),
                      ),
                    ),
                  ),
                ],
              ),
              if (_device.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    '${_device['manufacturer'] ?? ''} ${_device['model'] ?? ''} · Android SDK ${_device['sdk'] ?? ''} · Snapy ${_device['snapy_version'] ?? ''}',
                    textAlign: TextAlign.center,
                    style: small,
                  ),
                ),
              const SizedBox(height: 24),
            ]);
          },
        ),
      ),
    );
  }
}
