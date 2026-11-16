import 'package:flutter/material.dart';

import '../core/next_api.dart';
import '../core/snapy_core.dart';
import '../core/theme.dart';
import '../i18n/i18n.dart';
import 'app_system_icon.dart';
import 'common.dart';

/// Full-page dedicated manager for app and reel limits across all installed apps.
class AppLimitsPage extends StatefulWidget {
  const AppLimitsPage({super.key});

  @override
  State<AppLimitsPage> createState() => _AppLimitsPageState();
}

class _AppLimitsPageState extends State<AppLimitsPage> {
  List<Map<String, dynamic>> _allApps = [];
  List<Map<String, dynamic>> _filteredApps = [];
  Map<String, dynamic> _prefs = {};
  // reel limits: the one store (ReelLimits / runtime reel_limits) and the core catalogue of
  // short-video apps (core/rules android.social_apps) - no package-name guessing
  Map<String, ReelLimit> _reel = {};
  Set<String> _shortVideo = {};
  bool _loading = true;
  String _searchQuery = '';
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final apps = await SnapyCore.getInstalledApps();
      final prefs = await SnapyCore.rcPrefs();
      final reel = await NextApi.reelLimits();
      final catalogue = await NextApi.shortVideoApps();

      if (mounted) {
        setState(() {
          _allApps = apps;
          _prefs = prefs;
          _reel = reel;
          _shortVideo = {for (final a in catalogue) a.package, for (final a in apps) if (a['is_social'] == true) '${a['package']}'};
          _filterApps();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _filterApps() {
    if (_searchQuery.trim().isEmpty) {
      _filteredApps = List.from(_allApps);
    } else {
      final q = _searchQuery.toLowerCase();
      _filteredApps = _allApps.where((a) {
        final label = (a['label'] as String? ?? '').toLowerCase();
        final pkg = (a['package'] as String? ?? '').toLowerCase();
        return label.contains(q) || pkg.contains(q);
      }).toList();
    }
  }

  void _openConfigSheet(Map<String, dynamic> app) {
    final pkg = app['package'] as String;
    final isSocial = _shortVideo.contains(pkg);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: SnapyColors.of(context).card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => _AppLimitConfigSheet(
        app: app,
        isSocial: isSocial,
        // off until the user sets one; soft (a reminder) unless they opt in to the hard lock
        currentReelLimit: _reel[pkg]?.limit ?? 0,
        currentTimeLimitMin: _prefs['time_limit_$pkg'] as int? ?? 0,
        currentLock: _reel[pkg]?.hard ?? false,
        onSave: (reelLimit, timeLimitMin, lock) async {
          await SnapyCore.setRcPrefs({'time_limit_$pkg': timeLimitMin});
          if (isSocial) await NextApi.setReelLimit(pkg, reelLimit, lock ? 'hard' : 'soft');
          await _load();
          if (mounted) toast(context, tr('limits.updated', {'app': '${app['label']}'}));
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('limits.title'), style: const TextStyle(fontWeight: FontWeight.w700)),
        backgroundColor: c.bg,
        elevation: 0,
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Search Bar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: tr('limits.search'),
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            setState(() {
                              _searchQuery = '';
                              _filterApps();
                            });
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: c.surface,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: c.hair)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: c.hair)),
                ),
                onChanged: (v) => setState(() {
                  _searchQuery = v;
                  _filterApps();
                }),
              ),
            ),

            // App list
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _filteredApps.isEmpty
                      ? Center(
                          child: Text(
                            _searchQuery.isEmpty ? tr('limits.no_apps') : tr('limits.no_match', {'q': _searchQuery}),
                            style: TextStyle(color: c.text2),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          itemCount: _filteredApps.length,
                          separatorBuilder: (ctx, i) => Divider(height: 1, color: c.hair),
                          itemBuilder: (context, i) {
                            final app = _filteredApps[i];
                            final pkg = app['package'] as String? ?? '';
                            final label = app['label'] as String? ?? pkg;
                            final reelLimit = _reel[pkg]?.limit ?? 0;
                            final timeLimit = _prefs['time_limit_$pkg'] as int? ?? 0;
                            final hasLimit = reelLimit > 0 || timeLimit > 0;

                            final isSocial = _shortVideo.contains(pkg);

                            final details = <String>[];
                            if (isSocial && reelLimit > 0) {
                              details.add(tr(_reel[pkg]?.hard == true ? 'limits.reels_hard' : 'limits.reels_soft', {'n': '$reelLimit'}));
                            }
                            if (timeLimit > 0) details.add(tr('limits.minutes', {'min': '$timeLimit'}));
                            if (details.isEmpty) details.add(tr('limits.none'));

                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              leading: AppSystemIcon(package: pkg, size: 38, cornerRadius: 9),
                              title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                              subtitle: Text(
                                details.join(' · '),
                                style: TextStyle(
                                  color: hasLimit ? c.accent : c.text3,
                                  fontSize: 13,
                                  fontWeight: hasLimit ? FontWeight.w600 : FontWeight.normal,
                                ),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (hasLimit)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 6),
                                      child: Icon(Icons.lock_rounded, size: 16, color: c.accent),
                                    ),
                                  const Icon(Icons.chevron_right, size: 20),
                                ],
                              ),
                              onTap: () => _openConfigSheet(app),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AppLimitConfigSheet extends StatefulWidget {
  final Map<String, dynamic> app;
  final bool isSocial;
  final int currentReelLimit;
  final int currentTimeLimitMin;
  final bool currentLock;
  final Function(int reelLimit, int timeLimitMin, bool lock) onSave;

  const _AppLimitConfigSheet({
    required this.app,
    required this.isSocial,
    required this.currentReelLimit,
    required this.currentTimeLimitMin,
    required this.currentLock,
    required this.onSave,
  });

  @override
  State<_AppLimitConfigSheet> createState() => _AppLimitConfigSheetState();
}

class _AppLimitConfigSheetState extends State<_AppLimitConfigSheet> {
  late int _reelLimit;
  late int _timeLimitMin;
  late bool _lock;

  @override
  void initState() {
    super.initState();
    _reelLimit = widget.currentReelLimit;
    _timeLimitMin = widget.currentTimeLimitMin;
    _lock = widget.currentLock;
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final pkg = widget.app['package'] as String;
    final label = widget.app['label'] as String;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(width: 36, height: 4, decoration: BoxDecoration(color: c.hairStrong, borderRadius: BorderRadius.circular(2))),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              AppSystemIcon(package: pkg, size: 40, cornerRadius: 10),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr('limits.configure', {'app': label}), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
                    Text(tr('limits.configure_sub'), style: TextStyle(color: c.text2, fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // 1. Reel Limit (for short-video / social apps)
          if (widget.isSocial) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(child: Text(tr('limits.reel_limit'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15))),
                Text(_reelLimit > 0 ? tr('limits.reels_n', {'n': '$_reelLimit'}) : tr('limits.off'), style: TextStyle(color: c.accent, fontWeight: FontWeight.w700)),
              ],
            ),
            Slider(
              value: _reelLimit.toDouble(),
              min: 0,
              max: 300,
              divisions: 30,
              activeColor: c.accent,
              onChanged: (v) => setState(() => _reelLimit = v.toInt()),
            ),
            const SizedBox(height: 12),
          ],

          // 2. Daily Time Limit
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(child: Text(tr('limits.time_limit'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15))),
              Text(_timeLimitMin > 0 ? '${_timeLimitMin}m (${_timeLimitMin ~/ 60}h ${_timeLimitMin % 60}m)' : tr('limits.no_limit'), style: TextStyle(color: c.green, fontWeight: FontWeight.w700)),
            ],
          ),
          Slider(
            value: _timeLimitMin.toDouble(),
            min: 0,
            max: 240,
            divisions: 16,
            activeColor: c.green,
            onChanged: (v) => setState(() => _timeLimitMin = v.toInt()),
          ),

          const SizedBox(height: 12),

          // 3. Hard lock (opt-in) vs the gentle reminder (default) - only for short-video apps
          if (widget.isSocial)
            SwitchListTile(
              key: const ValueKey('hard-lock'),
              contentPadding: EdgeInsets.zero,
              title: Text(tr('limits.hard_lock'), style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(
                tr(_lock ? 'limits.hard_lock_on' : 'limits.hard_lock_off', {'app': label}),
                style: TextStyle(color: c.text2, fontSize: 12),
              ),
              value: _lock,
              onChanged: _reelLimit > 0 ? (v) => setState(() => _lock = v) : null,
            ),

          const SizedBox(height: 18),

          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  child: Text(tr('common.cancel')),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () {
                    widget.onSave(_reelLimit, _timeLimitMin, _lock);
                    Navigator.pop(context);
                  },
                  style: FilledButton.styleFrom(backgroundColor: c.accent, minimumSize: const Size.fromHeight(48)),
                  child: Text(tr('limits.save')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
