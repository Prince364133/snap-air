"""Windows' own neural/OneCore voices (e.g. Hindi "Microsoft Hemant / Kalpana",
Tamil "Valluvar", Telugu…), through the WinRT SpeechSynthesizer.

They ship with Windows and are licensed to the PC's user, so they are the
commercially safe native voice for languages whose open voices are
non-commercial. The user adds them in Settings → Time & language → Speech →
"Add voices" (Snapy opens that page for them).
"""
import io
import threading
import wave

import numpy as np
from src import diag  # noqa: E402

_lock = threading.Lock()


def _synth_mod():
    from winrt.windows.media.speechsynthesis import SpeechSynthesizer
    return SpeechSynthesizer


def voices():
    """[(display_name, language_tag, id)] of installed Windows voices."""
    try:
        SS = _synth_mod()
        return [(v.display_name, v.language, v.id) for v in SS.all_voices]
    except Exception as e:
        diag.record("winvoice.list", e, quiet=True)
        return []


def find(lang):
    """Best installed voice for a 2-letter language code (prefers <lang>-IN)."""
    vs = [v for v in voices() if v[1].lower().split("-")[0] == lang]
    vs.sort(key=lambda v: (not v[1].upper().endswith("-IN"),))
    return vs[0] if vs else None


class WindowsVoice:
    def __init__(self, voice_id):
        SS = _synth_mod()
        self.synth = SS()
        for v in SS.all_voices:
            if v.id == voice_id:
                self.synth.voice = v
                break
        self.name = self.synth.voice.display_name

    def synthesize(self, text, speed=1.0):
        import asyncio
        from winrt.windows.storage.streams import DataReader

        with _lock:
            try:
                self.synth.options.speaking_rate = max(0.5, min(3.0, float(speed)))
            except Exception as e:
                diag.record("winvoice.rate", e, quiet=True)

            async def run():
                stream = await self.synth.synthesize_text_to_stream_async(text)
                reader = DataReader(stream.get_input_stream_at(0))
                await reader.load_async(stream.size)
                buf = bytearray(stream.size)
                reader.read_bytes(buf)
                return bytes(buf)

            data = asyncio.run(run())
        with wave.open(io.BytesIO(data)) as w:
            sr, n, width, ch = w.getframerate(), w.getnframes(), w.getsampwidth(), w.getnchannels()
            raw = w.readframes(n)
        audio = np.frombuffer(raw, dtype=np.int16 if width == 2 else np.uint8).astype(np.float32)
        audio = audio / 32768.0 if width == 2 else (audio - 128) / 128.0
        if ch > 1:
            audio = audio.reshape(-1, ch).mean(axis=1)
        return audio, sr
