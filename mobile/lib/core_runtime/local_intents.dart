// Device intents for the phone services (docs/ANDROID_NEXT_PLAN.md §5, §7): camera capture,
// SOS and the "I'm in a meeting" phrasing.
//
// Source of truth: the core intent domain `phone_device` (core/intents, owned by the shared
// core) when it exists; until then these local patterns (same intent names and named groups)
// are used. Entries: intent = capture_video | capture_photo | capture_stop | sos | sos_stop |
// sos_call | meeting_start | meeting_stop, optional named group `camera` (front|back|rear|selfie).
import 'core_data.dart';

class DeviceIntent {
  final String intent;
  final String? camera; // front | back (null = default)
  const DeviceIntent(this.intent, [this.camera]);

  @override
  String toString() => 'DeviceIntent($intent, $camera)';
}

class LocalIntents {
  static const domain = 'phone_device';

  /// The fallback patterns (case-insensitive, matched on lower-cased text without . , ! ?).
  /// Order matters: first match wins.
  static final List<(String, RegExp)> patterns = [
    ('capture_stop', RegExp(r'^(?:please )?(?:stop|end|finish) (?:the )?(?:video|recording|camera|filming)(?: recording)?(?: now)?$|^(?:video|recording) (?:band|rok) karo$')),
    ('capture_video', RegExp(
        r'^(?:please )?(?:take|record|shoot|start|make|capture)(?: a| an| the)? (?:(?<camera>front|back|rear|selfie) )?(?:camera )?(?:video|recording|clip)(?: (?:with|on|using|from) (?:the |my )?(?<camera2>front|back|rear|selfie)(?: camera)?)?(?: now)?$|'
        r'^(?:please )?(?:start )?(?:video|filming) (?:with|on|using) (?:the |my )?(?<camera3>front|back|rear|selfie) camera$|'
        r'^(?<camera4>front|back|selfie) camera (?:se )?video (?:banao|record karo|lo)$')),
    ('capture_photo', RegExp(
        r'^(?:please )?(?:take|click|capture|snap)(?: a| an| my)? (?:(?<camera>front|back|rear) )?(?:camera )?(?:photo|picture|pic|selfie|snap)(?: (?:with|on|using|from) (?:the |my )?(?<camera2>front|back|rear|selfie)(?: camera)?)?(?: now)?$|'
        r'^(?:photo|selfie|pic) (?:khincho|lo|click karo)$')),
    ('sos_stop', RegExp(r"^(?:stop|cancel|end|turn off) (?:the )?(?:sos|emergency|alarm|siren)(?: mode| alert| alarm)?$|^i'?m (?:ok|okay|safe|fine) now$|^i am (?:ok|okay|safe|fine) now$")),
    ('sos_call', RegExp(r'^(?:call|dial|phone) (?:the )?(?:emergency(?: number| services)?|ambulance|police|112|911|999)(?: now| please)?$')),
    ('sos', RegExp(r"^(?:start |trigger |activate )?(?:sos|emergency|emergency mode|emergency alert)(?: please| now)?$|^(?:help me|i need help|bachao|madad karo)(?: please| now)?$")),
    ('meeting_start', RegExp(
        r"\b(?:i'?m|i am|we'?re|we are) (?:in|on|starting) a (?:meeting|call)\b.{0,30}\b(?:take|start|record|make)\b.{0,12}\bnotes?\b|"
        r"\b(?:take|start|record|make)\b.{0,12}\bnotes?\b.{0,20}\b(?:i'?m|i am|we'?re|we are) (?:in|on) a (?:meeting|call)\b|"
        r"^(?:i'?m|i am) in a meeting$|^meeting (?:chal rahi hai|shuru)[ ,]+notes? (?:lo|lena)$")),
    ('meeting_stop', RegExp(
        r"\b(?:meeting|call) (?:is )?(?:over|done|finished|ended|khatam)\b|\bsave (?:the |my )?(?:meeting )?notes\b|^(?:end|stop|finish) (?:the )?meeting$")),
  ];

  static String _norm(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'[.,!?;]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  static String? _camera(RegExpMatch m) {
    for (final g in ['camera', 'camera2', 'camera3', 'camera4']) {
      String? v;
      try {
        v = m.namedGroup(g);
      } catch (_) {
        v = null; // this alternative has no such group
      }
      if (v != null && v.isNotEmpty) return v == 'selfie' ? 'front' : (v == 'rear' ? 'back' : v);
    }
    return null;
  }

  static bool hasCoreDomain(CoreData core) {
    final d = core.intentIndex['domains'];
    return d is Map && d.containsKey(domain);
  }

  /// The device intent in [text], or null.
  static DeviceIntent? parse(String text, {CoreData? core}) {
    final low = _norm(text);
    if (low.isEmpty) return null;
    if (core != null && hasCoreDomain(core)) {
      // the core domain: one named group `camera`, its words mapped by slot_values.phone_device.camera
      // (front/selfie/rear/back and the Devanagari words); see core/README.md §4.8
      final map = (() {
        try {
          final v = core.slotValues('phone_device.camera');
          return v is Map ? v : const {};
        } catch (_) {
          return const {};
        }
      })();
      for (final (entry, m) in core.matches(domain, low)) {
        String? cam;
        try {
          cam = m.namedGroup('camera');
        } catch (_) {
          cam = null; // this entry has no camera group
        }
        final mapped = cam == null || cam.isEmpty ? null : (map[cam.toLowerCase()] ?? _camera(m));
        return DeviceIntent(entry.intent ?? '', mapped is String ? mapped : null);
      }
      return null;
    }
    for (final (intent, rx) in patterns) {
      final m = rx.firstMatch(low);
      if (m == null) continue;
      var cam = _camera(m);
      if (intent == 'capture_photo' && cam == null && RegExp(r'\bselfie\b').hasMatch(low)) cam = 'front';
      return DeviceIntent(intent, cam);
    }
    return null;
  }
}
