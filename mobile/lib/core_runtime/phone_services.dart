// Pure logic for the phone services (docs/ANDROID_NEXT_PLAN.md §4, §6, §7), mirrored in Kotlin:
//   VolumeCombo   -> Activation.kt (VolumeCombo)         volume Up+Down held 2800 ms
//   CaptionClock  -> Captions.kt (CaptionClock)          caption capsule timing
//   SosMachine    -> SosActivity.kt (SosMachine, Morse)  SOS states + torch strobe pattern
// Kept free of Flutter/IO so test/phone_services_test.dart pins the behaviour both follow.

/// Volume Up + Down held together for [holdMs] -> one activation. Only the combo is consumed:
/// single presses, and both keys before the hold completes, reach Android untouched; after the
/// combo fires, the rest of that press (repeats and the key-ups) is consumed so the volume
/// doesn't jump while the user lets go.
class VolumeCombo {
  final int holdMs;
  int? _upAt, _downAt;
  bool _fired = false;
  VolumeCombo({this.holdMs = 2800});

  bool get bothDown => _upAt != null && _downAt != null;

  /// When the combo fires if both keys stay down (null = not armed).
  int? get fireAt => bothDown && !_fired ? (_upAt! > _downAt! ? _upAt! : _downAt!) + holdMs : null;

  /// A volume key event. [up] = KEYCODE_VOLUME_UP (else VOLUME_DOWN). Returns true to consume it.
  bool onKey({required bool up, required bool down, required int t}) {
    if (down) {
      if (up) {
        _upAt ??= t;
      } else {
        _downAt ??= t;
      }
      return _fired; // key repeats after the combo fired
    }
    if (up) {
      _upAt = null;
    } else {
      _downAt = null;
    }
    final consume = _fired;
    if (_upAt == null && _downAt == null) _fired = false; // both released: re-arm
    return consume;
  }

  /// The timer check (Kotlin: a Handler callback at [fireAt]). True exactly once per hold.
  bool poll(int t) {
    final at = fireAt;
    if (at == null || t < at) return false;
    _fired = true;
    return true;
  }
}

/// The caption capsule under the camera (§6): the user's live words while listening, Snapy's
/// reply while speaking, gone [fadeMs] after speech ends.
class CaptionClock {
  final int fadeMs;
  final int thinkingMs;
  String text = '';
  int hideAt = 0;
  bool speaking = false;
  CaptionClock({this.fadeMs = 2000, this.thinkingMs = 8000});

  /// Rough TTS length so the capsule stays while Android speaks (refined by [speechDone]).
  static int speakMs(String text) {
    final words = text.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    final ms = words * 380;
    return ms < 1200 ? 1200 : ms;
  }

  /// {"type":"voice", state, text}: listening | partial | thinking | idle | error | level.
  void voice(String state, String t, int now) {
    switch (state) {
      case 'listening':
      case 'partial':
        if (t.trim().isNotEmpty) text = t.trim();
        hideAt = now + fadeMs + (state == 'listening' ? 4000 : 0);
      case 'thinking':
        if (t.trim().isNotEmpty) text = t.trim();
        hideAt = now + thinkingMs;
      case 'idle':
      case 'error':
        if (!speaking) hideAt = now + fadeMs;
      default:
        break; // level: no text change
    }
  }

  /// {"type":"speak", text}.
  void speak(String t, int now) {
    if (t.trim().isEmpty) return;
    text = t.trim();
    speaking = true;
    hideAt = now + speakMs(text) + fadeMs;
  }

  /// TTS finished (or was stopped): fade [fadeMs] later.
  void speechDone(int now) {
    speaking = false;
    hideAt = now + fadeMs;
  }

  bool visible(int now) => text.isNotEmpty && now < hideAt;
}

/// Offline SOS (§7): strobe + alarm + ICE card; "call the emergency number?" needs a yes.
class SosMachine {
  static const idle = 'idle', active = 'active', confirming = 'confirming';
  String state = idle;
  int startedAt = 0;
  String number;
  SosMachine({this.number = '112'});

  bool start(int now) {
    if (state != idle) return false;
    state = active;
    startedAt = now;
    return true;
  }

  /// "Call emergency number?" — asks first (never dials without a tap/yes).
  bool askCall() {
    if (state != active) return false;
    state = confirming;
    return true;
  }

  /// The yes: returns the number to put in the dialer (ACTION_DIAL, the user presses call).
  String? confirmCall() {
    if (state != confirming) return null;
    state = active;
    return number;
  }

  void cancelCall() {
    if (state == confirming) state = active;
  }

  bool stop() {
    if (state == idle) return false;
    state = idle;
    return true;
  }

  bool get alarming => state != idle;

  /// The torch strobe: Morse "SOS" (··· ——— ···), [unitMs] per dot, looping with a word gap.
  static bool torchOn(int elapsedMs, {int unitMs = 200}) {
    final t = (elapsedMs ~/ unitMs) % _sosLength;
    return _sos[t];
  }

  static final List<bool> _sos = () {
    final out = <bool>[];
    void mark(int units) {
      out.addAll(List.filled(units, true));
      out.add(false); // gap between marks
    }

    for (final letter in const [
      [1, 1, 1],
      [3, 3, 3],
      [1, 1, 1],
    ]) {
      for (final m in letter) {
        mark(m);
      }
      out.addAll(const [false, false]); // letter gap (3 units with the mark gap)
    }
    out.addAll(const [false, false, false, false]); // word gap (7 units)
    return out;
  }();

  static int get _sosLength => _sos.length;
}
