import 'package:flutter/material.dart';

import '../core/snapy_core.dart';
import '../core/theme.dart';
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

      if (mounted) {
        setState(() {
          _allApps = apps;
          _prefs = prefs;
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
    final isSocial = app['is_social'] == true ||
        pkg.contains('instagram') ||
        pkg.contains('youtube') ||
        pkg.contains('facebook') ||
        pkg.contains('tiktok') ||
        pkg.contains('snapchat') ||
        pkg.contains('reddit');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: SnapyColors.of(context).card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => _AppLimitConfigSheet(
        app: app,
        isSocial: isSocial,
        currentReelLimit: _prefs['limit_$pkg'] as int? ?? (isSocial ? 100 : 0),
        currentTimeLimitMin: _prefs['time_limit_$pkg'] as int? ?? 0,
        currentLock: _prefs['lock_$pkg'] as bool? ?? true,
        onSave: (reelLimit, timeLimitMin, lock) async {
          await SnapyCore.setRcPrefs({
            'limit_$pkg': reelLimit,
            'time_limit_$pkg': timeLimitMin,
            'lock_$pkg': lock,
          });
          await SnapyCore.setAppReelLimit(pkg, reelLimit, lock);
          await _load();
          if (mounted) toast(context, 'Limits updated for ${app['label']}');
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('App & Reel Limits', style: TextStyle(fontWeight: FontWeight.w700)),
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
                  hintText: 'Search installed apps...',
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
                            _searchQuery.isEmpty ? 'No installed apps detected' : 'No apps match "$_searchQuery"',
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
                            final reelLimit = _prefs['limit_$pkg'] as int? ?? 0;
                            final timeLimit = _prefs['time_limit_$pkg'] as int? ?? 0;
                            final hasLimit = reelLimit > 0 || timeLimit > 0;

                            final isSocial = app['is_social'] == true ||
                                pkg.contains('instagram') ||
                                pkg.contains('youtube') ||
                                pkg.contains('facebook') ||
                                pkg.contains('tiktok') ||
                                pkg.contains('snapchat') ||
                                pkg.contains('reddit');

                            final details = <String>[];
                            if (isSocial && reelLimit > 0) details.add('$reelLimit reels');
                            if (timeLimit > 0) details.add('${timeLimit}m limit');
                            if (details.isEmpty) details.add('No limits set');

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
                    Text('Configure $label', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
                    Text('Set usage boundaries and locks', style: TextStyle(color: c.text2, fontSize: 13)),
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
                const Text('Daily Reel Limit', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                Text(_reelLimit > 0 ? '$_reelLimit reels' : 'Disabled (off)', style: TextStyle(color: c.accent, fontWeight: FontWeight.w700)),
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
              const Text('Daily Screen Time Limit', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              Text(_timeLimitMin > 0 ? '${_timeLimitMin}m (${_timeLimitMin ~/ 60}h ${_timeLimitMin % 60}m)' : 'No limit', style: TextStyle(color: c.green, fontWeight: FontWeight.w700)),
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

          // 3. Hard Lock vs Gentle Nudge
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enforce Hard Feed Lock', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              _lock ? 'Automatically exits reels or app when limit is hit' : 'Displays a subtle floating reminder without blocking',
              style: TextStyle(color: c.text2, fontSize: 12),
            ),
            value: _lock,
            onChanged: (v) => setState(() => _lock = v),
          ),

          const SizedBox(height: 18),

          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  child: const Text('Cancel'),
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
                  child: const Text('Save Boundaries'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
