import math
import time


class LowPassFilter:
    def __init__(self):
        self.s = None

    def filter(self, value, alpha):
        if self.s is None:
            self.s = value
        else:
            self.s = alpha * value + (1.0 - alpha) * self.s
        return self.s

    def reset(self):
        self.s = None


class OneEuroFilter:
    """One-Euro filter (Casiez et al. 2012).

    Low speed -> low cutoff -> heavy smoothing (no jitter while hovering).
    High speed -> high cutoff -> little smoothing (no lag while moving).
    """

    def __init__(self, min_cutoff=1.0, beta=0.01, d_cutoff=1.0):
        self.min_cutoff = min_cutoff
        self.beta = beta
        self.d_cutoff = d_cutoff
        self.x_filter = LowPassFilter()
        self.dx_filter = LowPassFilter()
        self.last_time = None
        self.last_raw = None

    @staticmethod
    def _alpha(cutoff, dt):
        tau = 1.0 / (2.0 * math.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)

    def reset(self):
        self.x_filter.reset()
        self.dx_filter.reset()
        self.last_time = None
        self.last_raw = None

    def filter(self, x, timestamp=None):
        if timestamp is None:
            timestamp = time.perf_counter()

        if self.last_time is None:
            self.last_time = timestamp
            self.last_raw = x
            self.dx_filter.filter(0.0, 1.0)
            return self.x_filter.filter(x, 1.0)

        dt = timestamp - self.last_time
        if dt <= 0:
            dt = 1e-3
        self.last_time = timestamp

        dx = (x - self.last_raw) / dt
        self.last_raw = x
        edx = self.dx_filter.filter(dx, self._alpha(self.d_cutoff, dt))
        cutoff = self.min_cutoff + self.beta * abs(edx)
        return self.x_filter.filter(x, self._alpha(cutoff, dt))
