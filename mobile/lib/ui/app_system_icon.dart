import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/snapy_core.dart';

/// Renders the genuine launcher icon for any installed app fetched directly from the device package manager.
class AppSystemIcon extends StatefulWidget {
  final String package;
  final double size;
  final double cornerRadius;
  const AppSystemIcon({
    super.key,
    required this.package,
    this.size = 28,
    this.cornerRadius = 7,
  });

  @override
  State<AppSystemIcon> createState() => _AppSystemIconState();
}

class _AppSystemIconState extends State<AppSystemIcon> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(AppSystemIcon old) {
    super.didUpdateWidget(old);
    if (old.package != widget.package) _fetch();
  }

  Future<void> _fetch() async {
    final b = await SnapyCore.getAppIcon(widget.package);
    if (mounted) setState(() => _bytes = b);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final r = widget.cornerRadius;

    if (_bytes != null && _bytes!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(r),
        child: Image.memory(
          _bytes!,
          width: s,
          height: s,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
    }

    final pkg = widget.package.toLowerCase();
    Color bg = const Color(0xFF28C8FF).withValues(alpha: 0.18);
    IconData icon = Icons.apps_rounded;
    if (pkg.contains('instagram')) {
      bg = const Color(0xFFDD2A7B).withValues(alpha: 0.22);
      icon = Icons.camera_alt_outlined;
    } else if (pkg.contains('youtube')) {
      bg = const Color(0xFFFF0000).withValues(alpha: 0.22);
      icon = Icons.play_arrow_rounded;
    } else if (pkg.contains('whatsapp')) {
      bg = const Color(0xFF25D366).withValues(alpha: 0.22);
      icon = Icons.chat_bubble_outline;
    } else if (pkg.contains('facebook')) {
      bg = const Color(0xFF1877F2).withValues(alpha: 0.22);
      icon = Icons.facebook;
    } else if (pkg.contains('snapchat')) {
      bg = const Color(0xFFFFFC00).withValues(alpha: 0.25);
      icon = Icons.photo_camera_outlined;
    } else if (pkg.contains('chrome')) {
      bg = const Color(0xFF4285F4).withValues(alpha: 0.22);
      icon = Icons.public;
    } else if (pkg.contains('twitter') || pkg.contains('x.android')) {
      bg = const Color(0xFF1DA1F2).withValues(alpha: 0.22);
      icon = Icons.tag;
    }

    return Container(
      width: s,
      height: s,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(r),
      ),
      child: Icon(icon, size: s * 0.58, color: Colors.white70),
    );
  }
}
