// Pure phone-service logic: volume combo timing, caption timing, SOS states, device intents,
// meeting Markdown, API-key error mapping (§1 copy).
import 'package:flutter_test/flutter_test.dart';
import 'package:snapy/core_runtime/local_intents.dart';
import 'package:snapy/core_runtime/meeting_audio.dart';
import 'package:snapy/core_runtime/phone_services.dart';
import 'package:snapy/core_runtime/runtime.dart';

void main() {
  group('wakeMatches (mirror of WakeMatch.kt)', () {
    const phrases = ['hey snappy', 'snappy', 'hi snappy', 'okay snappy', 'hey meera'];
    test('the wake word alone', () {
      expect(wakeMatches('hey snappy', phrases), isTrue);
      expect(wakeMatches('  Hey   SNAPPY ', phrases), isTrue);
    });
    test('wake word followed by a command (Vosk: [unk] for the rest)', () {
      expect(wakeMatches('hey snappy [unk] [unk]', phrases), isTrue);
      expect(wakeMatches('[unk] snappy [unk]', phrases), isTrue);
    });
    test('never on noise, "hey" alone, or a dropped unknown name', () {
      expect(wakeMatches('', phrases), isFalse);
      expect(wakeMatches(null, phrases), isFalse);
      expect(wakeMatches('[unk]', phrases), isFalse);
      expect(wakeMatches('hey', phrases), isFalse);           // "hey meera" with "meera" not in the model
      expect(wakeMatches('hey [unk]', phrases), isFalse);
      expect(wakeMatches('snappyish', ['snappy']), isFalse);  // whole words only
    });
  });

  group('VolumeCombo (2800 ms)', () {
    test('fires once when both keys are held 2800 ms, consumes only after firing', () {
      final c = VolumeCombo();
      expect(c.onKey(up: true, down: true, t: 0), isFalse, reason: 'volume up works normally');
      expect(c.fireAt, isNull);
      expect(c.onKey(up: false, down: true, t: 100), isFalse);
      expect(c.fireAt, 2900);
      expect(c.poll(2899), isFalse);
      expect(c.poll(2900), isTrue);
      expect(c.poll(3500), isFalse, reason: 'once per hold');
      expect(c.onKey(up: true, down: true, t: 3000), isTrue, reason: 'repeats after the combo are consumed');
      expect(c.onKey(up: true, down: false, t: 3100), isTrue);
      expect(c.onKey(up: false, down: false, t: 3200), isTrue);
      // re-armed
      expect(c.onKey(up: true, down: true, t: 5000), isFalse);
    });

    test('releasing a key early cancels', () {
      final c = VolumeCombo();
      c.onKey(up: true, down: true, t: 0);
      c.onKey(up: false, down: true, t: 0);
      c.onKey(up: false, down: false, t: 2000);
      expect(c.fireAt, isNull);
      expect(c.poll(5000), isFalse);
    });

    test('a single held key never fires', () {
      final c = VolumeCombo();
      c.onKey(up: true, down: true, t: 0);
      expect(c.poll(10000), isFalse);
    });
  });

  group('CaptionClock', () {
    test('live words while listening, gone 2 s after speech ends', () {
      final c = CaptionClock();
      c.voice('partial', 'open you', 0);
      expect(c.visible(1000), isTrue);
      expect(c.text, 'open you');
      c.voice('thinking', 'open youtube', 1000);
      expect(c.visible(5000), isTrue, reason: 'thinking keeps it');
      c.speak('Opening YouTube.', 1200);
      expect(c.text, 'Opening YouTube.');
      expect(c.visible(1200 + CaptionClock.speakMs('Opening YouTube.') + 1999), isTrue);
      c.speechDone(3000);
      expect(c.visible(4999), isTrue);
      expect(c.visible(5000), isFalse);
    });

    test('idle while speaking does not cut the reply', () {
      final c = CaptionClock();
      c.speak('A long answer with many words in it for the test', 0);
      c.voice('idle', '', 100);
      expect(c.visible(2500), isTrue);
    });
  });

  group('SosMachine', () {
    test('start -> ask -> confirm dials; cancel returns; stop ends', () {
      final s = SosMachine(number: '112');
      expect(s.askCall(), isFalse, reason: 'not active');
      expect(s.start(0), isTrue);
      expect(s.start(5), isFalse);
      expect(s.confirmCall(), isNull, reason: 'never dials without the question');
      expect(s.askCall(), isTrue);
      s.cancelCall();
      expect(s.state, SosMachine.active);
      s.askCall();
      expect(s.confirmCall(), '112');
      expect(s.alarming, isTrue);
      expect(s.stop(), isTrue);
      expect(s.alarming, isFalse);
    });

    test('Morse SOS strobe', () {
      final on = [for (var u = 0; u < 12; u++) SosMachine.torchOn(u * 200)];
      // S = dot gap dot gap dot, then a letter gap
      expect(on.sublist(0, 6), [true, false, true, false, true, false]);
      expect(SosMachine.torchOn(6 * 200), isFalse);
      // O starts with a 3-unit dash
      expect([for (var u = 8; u < 11; u++) SosMachine.torchOn(u * 200)], [true, true, true]);
    });
  });

  group('device intents (local patterns until core has phone_device)', () {
    DeviceIntent? p(String s) => LocalIntents.parse(s);
    test('capture', () {
      expect(p('take a video with the front camera')?.intent, 'capture_video');
      expect(p('take a video with the front camera')?.camera, 'front');
      expect(p('record a video')?.camera, isNull);
      expect(p('start recording with the back camera')?.camera, 'back');
      expect(p('take a photo')?.intent, 'capture_photo');
      expect(p('take a selfie')?.camera, 'front');
      expect(p('Stop recording.')?.intent, 'capture_stop');
    });
    test('SOS', () {
      expect(p('emergency')?.intent, 'sos');
      expect(p('help me')?.intent, 'sos');
      expect(p('call emergency')?.intent, 'sos_call');
      expect(p('stop SOS')?.intent, 'sos_stop');
      expect(p('emergency contact list'), isNull);
    });
    test('meeting', () {
      expect(p("I'm in a meeting, take notes")?.intent, 'meeting_start');
      expect(p('take notes, I am in a meeting')?.intent, 'meeting_start');
      expect(p('Meeting is over, save the notes')?.intent, 'meeting_stop');
      expect(p('what is a meeting'), isNull);
    });
  });

  group('meeting Markdown', () {
    test('title, participants, decisions, action items with owners, transcript', () {
      final md = meetingMarkdown({
        'title': 'Launch sync',
        'started': '2026-11-16T10:00',
        'duration': 1500,
        'summary': ['We agreed the date.'],
        'decisions': ['Ship on Friday'],
        'actions': [
          {'task': 'Send the deck', 'owner': 'me', 'mine': true, 'due': 'tomorrow', 'status': 'accepted', 'task_id': 't1'},
          {'task': 'Book the room', 'owner': 'Ravi', 'mine': false, 'status': 'pending'},
        ],
        'transcript': [
          {'t': 5, 'who': 'Room', 'text': 'Hello everyone'}
        ],
        'ai_summary': false,
      });
      expect(md, startsWith('# Launch sync'));
      expect(md, contains('25 min'));
      expect(md, contains('**Participants:** Room'));
      expect(md, contains('## Decisions\n- Ship on Friday'));
      expect(md, contains('- [x] Send the deck — me (due tomorrow) · added to tasks'));
      expect(md, contains('- [ ] Book the room — Ravi'));
      expect(md, contains('[00:05] Room: Hello everyone'));
    });
    test('slug', () {
      expect(slugify('Q4 Planning: Budget & Hiring!'), 'q4-planning-budget-hiring');
      expect(slugify('***'), 'meeting');
    });
  });

  group('API key check (§1 copy table)', () {
    test('Gemini statuses map to the table rows', () {
      expect(SnapyRuntime.mapGeminiStatus(200, '{}'), 'ok');
      expect(SnapyRuntime.mapGeminiStatus(400, '{"error":{"status":"INVALID_ARGUMENT","message":"API key not valid. Please pass a valid API key.","details":[{"reason":"API_KEY_INVALID"}]}}'), 'invalid_key');
      expect(SnapyRuntime.mapGeminiStatus(401, '{"error":{"status":"UNAUTHENTICATED"}}'), 'invalid_key');
      expect(SnapyRuntime.mapGeminiStatus(403, '{"error":{"status":"PERMISSION_DENIED","message":"Generative Language API has not been used in project 1 before or it is disabled."}}'), 'permission');
      expect(SnapyRuntime.mapGeminiStatus(403, '{"error":{"status":"FORBIDDEN"}}'), 'invalid_key');
      expect(SnapyRuntime.mapGeminiStatus(429, '{"error":{"status":"RESOURCE_EXHAUSTED"}}'), 'quota');
      expect(SnapyRuntime.mapGeminiStatus(400, '{"error":{"status":"FAILED_PRECONDITION","message":"User location is not supported for the API use."}}'), 'region');
    });
    test('exact messages and actions', () {
      expect(SnapyRuntime.keyMessage('ok'), "Connected — Snapy's AI brain is ready.");
      expect(SnapyRuntime.keyMessage('invalid_key'), "This key isn't valid. Copy it again, or create a new one.");
      expect(SnapyRuntime.keyMessage('permission'), "This key can't use the Gemini API. Enable it or create a new key.");
      expect(SnapyRuntime.keyMessage('quota'), "This key's free quota is used up. Wait, or use another key.");
      expect(SnapyRuntime.keyMessage('region'), "Gemini isn't available for this key's region.");
      expect(SnapyRuntime.keyMessage('network'), "No internet — try again when you're online.");
      expect(SnapyRuntime.keyAction('invalid_key'), 'get_key');
      expect(SnapyRuntime.keyAction('region'), 'help');
      expect(SnapyRuntime.keyAction('network'), 'retry');
      expect(SnapyRuntime.geminiKeyUrl, 'https://aistudio.google.com/apikey');
    });
    test('free-text errors (other providers)', () {
      expect(SnapyRuntime.mapKeyError('Google Gemini: API key not valid. Please pass a valid API key.').$1, 'invalid_key');
      expect(SnapyRuntime.mapKeyError('RESOURCE_EXHAUSTED quota').$1, 'quota');
      expect(SnapyRuntime.mapKeyError('SocketException: Failed host lookup').$1, 'network');
    });
  });
}
