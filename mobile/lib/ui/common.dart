import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/next_api.dart';
import '../core/theme.dart';
import '../i18n/i18n.dart';

/// A rounded card on the Snapy surface, with an optional icon + title header.
class SnapyCard extends StatelessWidget {
  final String? title;
  final String? subtitle;
  final IconData? icon;
  final Color? iconColor;
  final Widget? trailing;
  final List<Widget> children;
  final EdgeInsets padding;
  const SnapyCard({
    super.key,
    this.title,
    this.subtitle,
    this.icon,
    this.iconColor,
    this.trailing,
    required this.children,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
  });

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final tint = iconColor ?? c.accent;
    return Padding(
      padding: padding,
      child: Material(
        color: c.card,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLg), side: BorderSide(color: c.hair)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 6),
              child: Row(children: [
                if (icon != null) ...[
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: tint.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
                    child: Icon(icon, color: tint, size: 20),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Semantics(header: true, child: Text(title!, style: Theme.of(context).textTheme.titleMedium)),
                    if (subtitle != null) Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
                  ]),
                ),
                ?trailing,
              ]),
            ),
          ...children,
        ]),
      ),
    );
  }
}

/// The real launcher icon of [package] (via the `appIcon` contract method), or a soft letter
/// badge while it loads / when the phone can't give one.
class AppIconView extends StatefulWidget {
  final String package;
  final String label;
  final double size;
  const AppIconView({super.key, required this.package, required this.label, this.size = 36});

  @override
  State<AppIconView> createState() => _AppIconViewState();
}

class _AppIconViewState extends State<AppIconView> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AppIconView old) {
    super.didUpdateWidget(old);
    if (old.package != widget.package) _load();
  }

  Future<void> _load() async {
    final b = await NextApi.appIcon(widget.package, size: (widget.size * 3).round());
    if (mounted && b != null) setState(() => _bytes = b);
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final s = widget.size;
    final Widget child = _bytes != null
        ? Image.memory(_bytes!, width: s, height: s, gaplessPlayback: true, errorBuilder: (_, _, _) => _letter(c, s))
        : _letter(c, s);
    return Semantics(
      label: tr('home.app_icon', {'app': widget.label}),
      image: true,
      child: ClipRRect(borderRadius: BorderRadius.circular(s * 0.24), child: SizedBox(width: s, height: s, child: child)),
    );
  }

  Widget _letter(SnapyColors c, double s) {
    // a stable pastel per package, from the orb palette (no brand colours hardcoded)
    final base = orbPalette[widget.package.hashCode.abs() % orbPalette.length];
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [base.withValues(alpha: 0.30), base.withValues(alpha: 0.14)], begin: Alignment.topLeft, end: Alignment.bottomRight),
      ),
      alignment: Alignment.center,
      child: ExcludeSemantics(
        child: Text(
          widget.label.isNotEmpty ? widget.label.characters.first.toUpperCase() : '•',
          style: TextStyle(color: c.text, fontWeight: FontWeight.w700, fontSize: s * 0.42),
        ),
      ),
    );
  }
}

/// A slim rounded progress bar: accent, amber near the limit, red when it's reached.
class LimitBar extends StatelessWidget {
  final double value;
  const LimitBar({super.key, required this.value});

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final color = value >= 1 ? c.red : (value >= 0.8 ? c.orange : c.accent);
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(value: value.clamp(0, 1).toDouble(), minHeight: 6, backgroundColor: c.fill, valueColor: AlwaysStoppedAnimation(color)),
    );
  }
}

/// mm:ss (or h:mm:ss) for timers.
String clockOf(int seconds) {
  final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60, s = seconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// A snackbar with [text].
void toast(BuildContext context, String text) {
  final m = ScaffoldMessenger.maybeOf(context);
  m?.hideCurrentSnackBar();
  m?.showSnackBar(SnackBar(content: Text(text)));
}

/// Opens [url]; when the phone can't, copies it and says so.
Future<void> openLink(BuildContext context, String url) async {
  final ok = await NextApi.openUrl(url);
  if (ok || !context.mounted) return;
  await copyText(url);
  if (context.mounted) toast(context, tr('key.link_copied'));
}

Future<void> copyText(String text) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
  } catch (_) {}
}
