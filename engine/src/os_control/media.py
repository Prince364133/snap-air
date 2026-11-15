"""Knows when a video or music is playing (YouTube in Chrome/Edge, Spotify, VLC,
Netflix…) through the Windows media-session API — the same source as the media
controls in the volume flyout. Snapy uses it to stop treating the video's own
sound as commands: while media plays it only reacts to its name or the hotkey.
"""
import asyncio
import threading
import time

from src import appdata
from src import diag  # noqa: E402


class MediaWatcher:
    def __init__(self, on_change=None):
        self.on_change = on_change
        self.playing = False
        self.title = ""
        self.app = ""
        self.available = True
        self._stop = False

    def start(self):
        threading.Thread(target=self._loop, daemon=True).start()
        return self

    def stop(self):
        self._stop = True

    def poll(self):
        """One check: (playing, title, app)."""
        from winrt.windows.media.control import (
            GlobalSystemMediaTransportControlsSessionManager as Manager,
            GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status)

        async def go():
            mgr = await Manager.request_async()
            for s in mgr.get_sessions():
                if s.get_playback_info().playback_status == Status.PLAYING:
                    title = ""
                    try:
                        props = await s.try_get_media_properties_async()
                        title = props.title or ""
                    except Exception as e:
                        diag.record("media.properties", e, quiet=True)
                    return True, title, s.source_app_user_model_id or ""
            return False, "", ""
        return asyncio.run(go())

    def _loop(self):
        interval = float(appdata.get("timings.media_poll_s", 1.5))
        while not self._stop:
            try:
                playing, title, app = self.poll()
            except Exception as e:
                if self.available:
                    print("[Media] media sessions unavailable:", e)
                self.available = False
                return
            if playing != self.playing or title != self.title:
                self.playing, self.title, self.app = playing, title, app
                if self.on_change:
                    try:
                        self.on_change(self.state())
                    except Exception as e:
                        diag.record("media.on_change", e, quiet=True)
            time.sleep(interval)

    def state(self):
        return {"playing": self.playing, "title": self.title, "app": self.app}


class SystemAudioMeter:
    """Loudness of what the speakers are playing (WASAPI loopback), measured only
    while media plays. The voice listener uses it to tell the video's sound that
    leaks into the mic apart from the user's own voice. Nothing is stored."""

    def __init__(self):
        self.level = 0.0
        self.active = False
        self._thread = None

    def set_active(self, on):
        if on and not self.active:
            self.active = True
            self._thread = threading.Thread(target=self._run, daemon=True)
            self._thread.start()
        elif not on:
            self.active = False
            self.level = 0.0

    def _run(self):
        try:
            import numpy as np
            import soundcard as sc
            dev = sc.get_microphone(id=str(sc.default_speaker().name), include_loopback=True)
            with dev.recorder(samplerate=16000, channels=1, blocksize=1600) as rec:
                while self.active:
                    data = rec.record(numframes=1600)
                    x = data[:, 0] if data.ndim > 1 else data
                    self.level = 0.6 * self.level + 0.4 * float(np.sqrt(np.mean(x ** 2)))
        except Exception as e:
            print("[Media] loopback meter unavailable:", e)
        self.level = 0.0
