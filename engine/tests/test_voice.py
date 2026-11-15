"""End-to-end voice test: real speech audio (Windows TTS) -> endpointing ->
faster-whisper -> agent. Slow (~30 s); skipped where TTS isn't available.

Run:  .venv\\Scripts\\python -m unittest tests.test_voice
"""
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import wave

import numpy as np

from tests.test_agent import FakeApps, FakeOS

PHRASES = [
    ("Snap, scroll down", "scroll"),
    ("Hey Snap, scroll up three times", "scroll"),
    ("Snap, switch to Chrome", "focus"),
    ("Snap, open YouTube and play lo-fi hip hop", "youtube"),
    ("Snap, take note remember to review the PR", "note"),
    ("Snap, open snap air settings", "ui"),
    ("Snap, next tab", "tab"),
    ("Snap, keep scrolling", "autoscroll"),
    ("Snap, volume up", "media"),
    ("Snap, pause", "media"),
    ("Snap, minimize window", "window"),
    ("Snap, go back", "nav"),
    ("So I was telling him about the meeting yesterday", "ignored"),
]


def synth(phrases, out_dir):
    script = ["Add-Type -AssemblyName System.Speech",
              "$s = New-Object System.Speech.Synthesis.SpeechSynthesizer",
              "$f = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(16000,"
              "[System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen,"
              "[System.Speech.AudioFormat.AudioChannel]::Mono)"]
    for i, p in enumerate(phrases):
        script.append(f"$s.SetOutputToWaveFile('{out_dir}\\{i}.wav', $f); $s.Speak('{p}')")
    script.append("$s.SetOutputToNull()")
    subprocess.run(["powershell", "-NoProfile", "-Command", "; ".join(script)], check=True, timeout=120)


def load(path):
    w = wave.open(path)
    return np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32) / 32768


@unittest.skipUnless(sys.platform == "win32", "needs Windows TTS")
class VoicePipelineTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp()
        synth([p for p, _ in PHRASES], cls.dir)
        from src.voice.voice_listener import VoiceListener
        cls.v = VoiceListener()
        for _ in range(120):
            if cls.v.model is not None:
                break
            time.sleep(0.5)
        assert cls.v.model is not None, cls.v.model_error

    def test_endpointing_cuts_one_utterance_out_of_continuous_audio(self):
        """Feed silence + speech + silence in 100 ms chunks, like the mic does."""
        v = self.v
        rng = np.random.default_rng(0)
        speech = load(os.path.join(self.dir, "0.wav"))
        noise = lambda s: (rng.standard_normal(int(16000 * s)) * 0.003).astype(np.float32)  # noqa: E731
        stream = np.concatenate([noise(1.5), speech * 0.5 + noise(len(speech) / 16000), noise(1.5)])
        while not v.jobs.empty():
            v.jobs.get()
        got = []
        v.on_transcript_callback = lambda text, armed, *rest: got.append(text)
        v.is_running = True
        th = threading.Thread(target=v._capture, daemon=True)
        th.start()
        for i in range(0, len(stream), 1600):
            v.audio_queue.put(stream[i:i + 1600])
        deadline = time.time() + 15
        while not got and time.time() < deadline:
            time.sleep(0.1)
        v.is_running = False
        self.assertEqual(len(got), 1)
        self.assertIn("scroll down", got[0].lower())

    def test_spoken_commands_run_the_right_action(self):
        from src.ai.agent_controller import AgentController
        from src.config import Settings
        agent = AgentController(settings=Settings(os.path.join(self.dir, "s.json")),
                                os_actions=FakeOS(), app_index=FakeApps())
        agent.play_youtube = lambda q: None
        agent.set_callbacks(notes_callback=lambda t: None, ui_callback=lambda a, **k: None)
        failures, times = [], []
        for i, (phrase, expected) in enumerate(PHRASES):
            t = time.time()
            text = self.v.transcribe(load(os.path.join(self.dir, f"{i}.wav")))
            times.append(time.time() - t)
            r = agent.execute_intent(text, require_wake=True)
            agent.stop_autoscroll()
            if r.action != expected:
                failures.append(f"{phrase!r} -> heard {text!r} -> {r.action} ({r.message})")
        print(f"\n  avg transcription {sum(times) / len(times):.2f}s, max {max(times):.2f}s")
        self.assertEqual(failures, [])


if __name__ == "__main__":
    unittest.main()
