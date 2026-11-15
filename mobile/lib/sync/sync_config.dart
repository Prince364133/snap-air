/// Sync tunables. Same keys and defaults as engine/src/sync/conf.py (`sync.<key>`).
/// Pass overrides (e.g. from core/rules once the core runtime exposes them) to [SyncConfig].
class SyncConfig {
  static const Map<String, Object> defaults = {
    'port': 47390,
    'service_type': '_snapy._tcp.local',
    'beacon_group': '239.255.42.99',
    'beacon_port': 47391,
    'pairing_ttl_s': 300,
    'handshake_timeout_s': 10,
    'connect_timeout_s': 4,
    'discovery_timeout_s': 3,
    'idle_timeout_s': 600,
    'keepalive_s': 30,
    'resync_interval_s': 60,
    'max_frame_bytes': 4 * 1024 * 1024,
    'batch_records': 200,
    'tombstone_days': 30,
    'max_clock_skew_s': 86400,
    'max_text_chars': 10000,
    'max_focus_minutes': 480,
    'commands': ['link', 'note', 'text', 'start_my_day', 'focus', 'resume_context'],
  };

  final Map<String, Object> _values;

  SyncConfig([Map<String, Object>? overrides])
      : _values = {...defaults, ...?overrides};

  int i(String key) => (_values[key] as num).toInt();
  String s(String key) => _values[key] as String;
  List<String> list(String key) => List<String>.from(_values[key] as List);
}
