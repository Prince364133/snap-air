/// Send-to-laptop / send-to-phone commands, validated exactly like
/// engine/src/sync/session.py validate_command.
library;

import 'sync_config.dart';

class CommandException implements Exception {
  final String message;
  const CommandException(this.message);
  @override
  String toString() => 'CommandException: $message';
}

Map<String, dynamic> validateCommand(Object? cmd, [SyncConfig? cfg]) {
  final c = cfg ?? SyncConfig();
  if (cmd is! Map) throw const CommandException('command must be an object');
  final t = cmd['type'];
  if (t is! String || !c.list('commands').contains(t)) throw const CommandException('unknown command');
  final limit = c.i('max_text_chars');
  switch (t) {
    case 'link':
      final url = cmd['url'];
      if (url is! String || url.length > limit) throw const CommandException('link needs a url');
      final u = Uri.tryParse(url.trim());
      if (u == null || !(u.scheme == 'http' || u.scheme == 'https') || u.host.isEmpty) {
        throw const CommandException('only http(s) links');
      }
      final out = <String, dynamic>{'type': t, 'url': url.trim()};
      final title = cmd['title'];
      if (title is String) out['title'] = title.length > 200 ? title.substring(0, 200) : title;
      return out;
    case 'note':
    case 'text':
      final text = cmd['text'];
      if (text is! String || text.trim().isEmpty || text.length > limit) {
        throw CommandException('$t needs text');
      }
      return {'type': t, 'text': text};
    case 'start_my_day':
      return {'type': t};
    case 'focus':
      final m = cmd['minutes'];
      if (m is! num || m.toInt() < 1 || m.toInt() > c.i('max_focus_minutes')) {
        throw const CommandException('focus needs minutes');
      }
      return {'type': t, 'minutes': m.toInt()};
    case 'resume_context':
      final name = cmd['name'];
      if (name is! String || name.trim().isEmpty || name.length > 200) {
        throw const CommandException('resume_context needs a name');
      }
      return {'type': t, 'name': name.trim()};
  }
  throw const CommandException('unknown command');
}
