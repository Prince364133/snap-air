import 'package:flutter/material.dart';

import '../core/next_api.dart';
import '../core/theme.dart';
import '../i18n/i18n.dart';
import 'common.dart';

/// Memory vault: facts, notes and meetings Snapy keeps on this phone. Read them as Markdown,
/// export them, or clear a kind (after a confirmation).
class VaultPage extends StatefulWidget {
  final String initialKind;
  const VaultPage({super.key, this.initialKind = 'facts'});
  @override
  State<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<VaultPage> {
  static const kinds = ['facts', 'notes', 'meetings'];
  late String _kind = kinds.contains(widget.initialKind) ? widget.initialKind : 'facts';
  List<VaultItem> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final items = await NextApi.vaultList(_kind);
    if (mounted) setState(() { _items = items; _loading = false; });
  }

  Future<void> _export() async {
    final path = await NextApi.vaultExport(_kind);
    if (!mounted) return;
    toast(context, path == null ? tr('vault.export_failed') : tr('vault.export_done', {'path': path}));
  }

  Future<void> _clear() async {
    final kindLabel = tr('vault.$_kind');
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('vault.clear_title', {'kind': kindLabel})),
        content: Text(tr('vault.clear_body')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: SnapyColors.of(ctx).red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('vault.clear')),
          ),
        ],
      ),
    );
    if (yes != true) return;
    final ok = await NextApi.vaultClear(_kind);
    if (!mounted) return;
    toast(context, ok ? tr('vault.cleared') : tr('vault.clear_failed'));
    if (ok) _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('vault.title')),
        backgroundColor: c.bg,
        actions: [
          IconButton(tooltip: tr('vault.export'), icon: const Icon(Icons.ios_share), onPressed: _export),
          IconButton(tooltip: tr('vault.clear'), icon: const Icon(Icons.delete_outline), onPressed: _items.isEmpty ? null : _clear),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              segments: [for (final k in kinds) ButtonSegment(value: k, label: Text(tr('vault.$k')))],
              selected: {_kind},
              onSelectionChanged: (s) {
                setState(() => _kind = s.first);
                _load();
              },
            ),
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _items.isEmpty
                  ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(tr('vault.empty'), style: Theme.of(context).textTheme.bodySmall)))
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: _items.length,
                      separatorBuilder: (_, _) => Divider(height: 1, color: c.hair),
                      itemBuilder: (_, i) {
                        final it = _items[i];
                        return ListTile(
                          minTileHeight: 56,
                          title: Text(it.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                          subtitle: it.date == null ? null : Text(MaterialLocalizations.of(context).formatMediumDate(it.date!.toLocal())),
                          trailing: it.markdown.trim() == it.title.trim() ? null : const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => VaultItemPage(item: it))),
                        );
                      },
                    ),
        ),
      ]),
    );
  }
}

/// One vault item rendered as Markdown (headings, bullets, checkboxes, bold), selectable.
class VaultItemPage extends StatelessWidget {
  final VaultItem item;
  const VaultItemPage({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        backgroundColor: c.bg,
        actions: [
          IconButton(
            tooltip: MaterialLocalizations.of(context).copyButtonLabel,
            icon: const Icon(Icons.copy),
            onPressed: () async {
              await copyText(item.markdown);
              if (context.mounted) toast(context, MaterialLocalizations.of(context).copyButtonLabel);
            },
          ),
        ],
      ),
      body: SelectionArea(
        child: ListView(padding: const EdgeInsets.all(20), children: [MarkdownView(item.markdown.isEmpty ? item.title : item.markdown)]),
      ),
    );
  }
}

/// A tiny Markdown renderer — enough for Snapy's vault files (no package needed).
class MarkdownView extends StatelessWidget {
  final String source;
  const MarkdownView(this.source, {super.key});

  static List<InlineSpan> inline(String s, TextStyle base) {
    final out = <InlineSpan>[];
    final re = RegExp(r'\*\*(.+?)\*\*|`(.+?)`|\*(.+?)\*');
    var i = 0;
    for (final m in re.allMatches(s)) {
      if (m.start > i) out.add(TextSpan(text: s.substring(i, m.start), style: base));
      if (m.group(1) != null) {
        out.add(TextSpan(text: m.group(1), style: base.copyWith(fontWeight: FontWeight.w700)));
      } else if (m.group(2) != null) {
        out.add(TextSpan(text: m.group(2), style: base.copyWith(fontFamily: 'monospace')));
      } else {
        out.add(TextSpan(text: m.group(3), style: base.copyWith(fontStyle: FontStyle.italic)));
      }
      i = m.end;
    }
    if (i < s.length) out.add(TextSpan(text: s.substring(i), style: base));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = SnapyColors.of(context);
    final body = t.bodyMedium ?? const TextStyle(fontSize: 15);
    final blocks = <Widget>[];
    for (final raw in source.replaceAll('\r\n', '\n').split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        blocks.add(const SizedBox(height: 8));
        continue;
      }
      final h = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
      if (h != null) {
        final level = h.group(1)!.length;
        final style = level == 1 ? t.headlineMedium : (level == 2 ? t.titleMedium?.copyWith(fontSize: 19) : t.titleMedium);
        blocks.add(Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Semantics(header: true, child: Text.rich(TextSpan(children: inline(h.group(2)!, style ?? body)))),
        ));
        continue;
      }
      final task = RegExp(r'^\s*[-*]\s+\[( |x|X)\]\s+(.*)$').firstMatch(line);
      final bullet = RegExp(r'^\s*([-*•]|\d+\.)\s+(.*)$').firstMatch(line);
      if (task != null || bullet != null) {
        final done = task != null && task.group(1)!.toLowerCase() == 'x';
        final text = task?.group(2) ?? bullet!.group(2)!;
        final marker = task != null
            ? Icon(done ? Icons.check_box : Icons.check_box_outline_blank, size: 18, color: c.text2)
            : Text(RegExp(r'^\d+\.$').hasMatch(bullet!.group(1)!) ? bullet.group(1)! : '•', style: body);
        blocks.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 26, child: marker),
            Expanded(child: Text.rich(TextSpan(children: inline(text, body)))),
          ]),
        ));
        continue;
      }
      if (line.startsWith('>')) {
        blocks.add(Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: c.hairStrong, width: 3))),
          child: Text.rich(TextSpan(children: inline(line.replaceFirst(RegExp(r'^>\s?'), ''), body.copyWith(color: c.text2)))),
        ));
        continue;
      }
      blocks.add(Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text.rich(TextSpan(children: inline(line, body)))));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: blocks);
  }
}
