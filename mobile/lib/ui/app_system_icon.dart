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
    const palette = [
      Color(0xFF28C8FF),
      Color(0xFFDD2A7B),
      Color(0xFFFF453A),
      Color(0xFF30D158),
      Color(0xFFFF9F0A),
      Color(0xFFBF5AF2),
      Color(0xFF5E5CE6),
      Color(0xFF64D2FF),
    ];
    final color = palette[pkg.hashCode.abs() % palette.length];
    final label = SnapyCore.cachedAppLabel(widget.package);
    final initial = label.isNotEmpty ? label[0].toUpperCase() : 'A';

    return Container(
      width: s,
      height: s,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(r),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: color,
          fontSize: s * 0.48,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
