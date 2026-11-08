"""Обработка звука: фильтры, огибающие, генераторы, реверберация, мастеринг, запись в OGG."""

import os
import subprocess
import tempfile

import numpy as np
from scipy import signal
from scipy.io import wavfile
from scipy.ndimage import minimum_filter1d, uniform_filter1d

SR = 44100


# --- Генераторы ---------------------------------------------------------------

def tt(dur):
    return np.arange(int(dur * SR)) / SR


def noise(dur, rng):
    return rng.uniform(-1.0, 1.0, int(dur * SR)).astype(np.float64)


def brown(dur, rng):
    """Коричневый шум (глухой, для гула и ветра)."""
    x = np.cumsum(rng.normal(0, 1, int(dur * SR)))
    x = signal.sosfilt(signal.butter(1, 20, "hp", fs=SR, output="sos"), x)
    return x / (np.max(np.abs(x)) + 1e-9)


def osc(freq, dur=None, shape="sine", phase=0.0):
    """Осциллятор с частотой-числом или массивом частот (для глиссандо)."""
    if np.isscalar(freq):
        freq = np.full(int(dur * SR), float(freq))
    ph = phase + 2 * np.pi * np.cumsum(freq) / SR
    if shape == "sine":
        return np.sin(ph)
    frac = (ph / (2 * np.pi)) % 1.0
    if shape == "saw":
        return 2.0 * frac - 1.0
    if shape == "square":
        return np.where(frac < 0.5, 1.0, -1.0)
    if shape == "tri":
        return 4.0 * np.abs(frac - 0.5) - 1.0
    raise ValueError(shape)


def glide(f0, f1, dur, curve=1.0):
    k = np.linspace(0, 1, int(dur * SR)) ** curve
    return f0 * (f1 / f0) ** k


def karplus(freq, dur, rng, decay=0.996, bright=0.5):
    """Щипок струны (Карплус-Стронг)."""
    n = int(dur * SR)
    period = max(2, int(SR / freq))
    buf = rng.uniform(-1, 1, period)
    out = np.zeros(n)
    prev = 0.0
    for i in range(n):
        j = i % period
        cur = buf[j]
        out[i] = cur
        buf[j] = decay * (bright * cur + (1 - bright) * prev)
        prev = cur
    return out


def bell(freq, dur, ratios=(0.5, 1.0, 1.19, 1.5, 2.0, 2.5, 2.66, 3.0, 4.07, 5.2),
         amps=(0.9, 1.0, 0.55, 0.4, 0.5, 0.25, 0.2, 0.2, 0.12, 0.08), decay=2.5, rng=None):
    """Колокол: негармонические обертоны, верхние затухают быстрее."""
    t = tt(dur)
    out = np.zeros_like(t)
    for i, (r, a) in enumerate(zip(ratios, amps)):
        d = decay / (1 + 0.6 * i)
        beat = 1 + 0.0015 * (i % 3)
        out += a * np.sin(2 * np.pi * freq * r * beat * t + i) * np.exp(-t / d)
    # мягкая атака и плавный конец, чтобы не щёлкало
    a = int(0.003 * SR)
    out[:a] *= np.linspace(0, 1, a)
    n = len(out) // 3
    out[-n:] *= np.cos(np.linspace(0, np.pi / 2, n)) ** 2
    return out


# --- Огибающие ----------------------------------------------------------------

def env_exp(dur, tau, attack=0.002):
    t = tt(dur)
    e = np.exp(-t / tau)
    a = int(attack * SR)
    if a > 0:
        e[:a] *= np.linspace(0, 1, a)
    return e


def env_ar(dur, attack, release, shape=2.0):
    """Подъём attack, затем спад до нуля к концу dur."""
    n = int(dur * SR)
    a = max(1, int(attack * SR))
    e = np.ones(n)
    e[:a] = np.linspace(0, 1, a) ** shape
    r = max(1, min(n - a, int(release * SR)))
    e[n - r:] *= np.linspace(1, 0, r) ** shape
    return e


def env_points(dur, points):
    """Ломаная огибающая: [(время, уровень), ...]."""
    t = tt(dur)
    xs, ys = zip(*points)
    return np.interp(t, xs, ys)


# --- Фильтры ------------------------------------------------------------------

def lp(x, fc, order=2):
    return signal.sosfilt(signal.butter(order, min(fc, SR * 0.45), "lp", fs=SR, output="sos"), x)


def hp(x, fc, order=2):
    return signal.sosfilt(signal.butter(order, fc, "hp", fs=SR, output="sos"), x)


def bp(x, lo, hi, order=2):
    return signal.sosfilt(signal.butter(order, [lo, min(hi, SR * 0.45)], "bp", fs=SR, output="sos"), x)


def _biquad(kind, f, q):
    w = 2 * np.pi * min(f, SR * 0.45) / SR
    alpha = np.sin(w) / (2 * q)
    c = np.cos(w)
    if kind == "lp":
        b = [(1 - c) / 2, 1 - c, (1 - c) / 2]
    elif kind == "hp":
        b = [(1 + c) / 2, -(1 + c), (1 + c) / 2]
    else:  # bp, постоянная пиковая громкость
        b = [alpha, 0, -alpha]
    a = [1 + alpha, -2 * c, 1 - alpha]
    return np.array(b) / a[0], np.array(a) / a[0]


def sweep(x, kind, freqs, q=0.9, block=128):
    """Фильтр с меняющейся частотой: freqs — число, пара (от, до) или массив длины x."""
    n = len(x)
    if np.isscalar(freqs):
        freqs = np.full(n, float(freqs))
    elif len(freqs) == 2:
        freqs = np.geomspace(freqs[0], freqs[1], n)
    out = np.zeros(n)
    zi = np.zeros(2)
    for s in range(0, n, block):
        b, a = _biquad(kind, freqs[s], q)
        out[s:s + block], zi = signal.lfilter(b, a, x[s:s + block], zi=zi)
    return out


def resonators(x, freqs, q=12.0, gains=None):
    """Набор узких резонансов (дерево, металл, формантные гласные)."""
    out = np.zeros_like(x)
    for i, f in enumerate(freqs):
        b, a = _biquad("bp", f, q)
        out += signal.lfilter(b, a, x) * (gains[i] if gains is not None else 1.0)
    return out


def formant(src, vowel_from, vowel_to=None, scale=1.0):
    """Фильтр гласной поверх источника (пила с голосовой частотой)."""
    vowels = {
        "a": ([730, 1090, 2440], [1.0, 0.5, 0.25]), "o": ([500, 850, 2400], [1.0, 0.45, 0.15]),
        "u": ([330, 750, 2300], [1.0, 0.3, 0.1]), "e": ([530, 1840, 2480], [1.0, 0.45, 0.25]),
        "i": ([300, 2200, 3000], [1.0, 0.35, 0.25]), "ae": ([660, 1720, 2410], [1.0, 0.5, 0.25]),
    }
    f0, g0 = vowels[vowel_from]
    f1, g1 = vowels[vowel_to or vowel_from]
    n = len(src)
    out = np.zeros(n)
    for k in range(3):
        fr = np.geomspace(f0[k] * scale, f1[k] * scale, n)
        out += sweep(src, "bp", fr, q=6.0 + 2 * k) * np.linspace(g0[k], g1[k], n)
    return out


def drive(x, amount=2.0):
    return np.tanh(x * amount) / np.tanh(amount)


def crackle(dur, rng, density=40.0, lo=1500, hi=9000, decay=0.004):
    """Треск: случайные короткие щелчки (огонь, лёд, кости)."""
    n = int(dur * SR)
    out = np.zeros(n)
    count = int(density * dur)
    click = np.exp(-np.arange(int(0.02 * SR)) / (decay * SR))
    for _ in range(count):
        pos = rng.integers(0, max(1, n - len(click)))
        out[pos:pos + len(click)] += click * rng.uniform(0.2, 1.0) * rng.choice([-1, 1])
    return bp(out, lo, hi)


# --- Пространство -------------------------------------------------------------

def reverb(x, rng, time=1.2, mix=0.25, damp=5000, predelay=0.012, stereo=True):
    """Свёртка с экспоненциально затухающим шумом. Возвращает стерео, если stereo."""
    mono = x if x.ndim == 1 else x.mean(axis=1)
    n = int(time * SR)
    t = np.arange(n) / SR
    chans = []
    for _ in range(2 if stereo else 1):
        ir = rng.normal(0, 1, n) * np.exp(-t * 6.9 / time)
        ir = lp(ir, damp)
        ir[: int(predelay * SR)] = 0
        ir /= np.sqrt(np.sum(ir ** 2)) + 1e-9
        wet = np.pad(signal.fftconvolve(mono, ir), (0, 1))[: len(mono) + n]
        chans.append(wet)
    dry = np.concatenate([mono, np.zeros(n)])
    if stereo:
        if x.ndim == 2:
            dry2 = np.concatenate([x, np.zeros((n, 2))])
        else:
            dry2 = np.stack([dry, dry], axis=1)
        wet = np.stack(chans, axis=1)
        return dry2 * (1 - mix) + wet * mix * 0.7
    return dry * (1 - mix) + chans[0] * mix * 0.7


def pan(x, position):
    """position от -1 (лево) до 1 (право), равная мощность."""
    a = (position + 1) * np.pi / 4
    return np.stack([x * np.cos(a), x * np.sin(a)], axis=1)


def place(dst, src, at, gain=1.0):
    """Подмешать src в dst с секунды at (обрезая по длине dst)."""
    i = int(at * SR)
    if i >= len(dst):
        return dst
    m = min(len(src), len(dst) - i)
    dst[i:i + m] += src[:m] * gain
    return dst


def place_wrap(dst, src, at, gain=1.0):
    """Как place, но хвост за концом петли переносится в начало."""
    i = int(at * SR) % len(dst)
    pos = 0
    while pos < len(src):
        m = min(len(src) - pos, len(dst) - i)
        dst[i:i + m] += src[pos:pos + m] * gain
        pos += m
        i = 0
    return dst


def shift_pitch(x, factor):
    """Сдвиг высоты пересэмплированием (меняется и длина)."""
    from fractions import Fraction
    fr = Fraction(1 / factor).limit_denominator(200)
    return signal.resample_poly(x, fr.numerator, fr.denominator, axis=0)


def fade(x, fin=0.0, fout=0.0):
    x = x.copy()
    a, b = int(fin * SR), int(fout * SR)
    if a:
        x[:a] *= np.linspace(0, 1, a)[:, None] if x.ndim == 2 else np.linspace(0, 1, a)
    if b:
        x[-b:] *= np.linspace(1, 0, b)[:, None] if x.ndim == 2 else np.linspace(1, 0, b)
    return x


# --- Мастеринг ----------------------------------------------------------------

def loudness_db(x):
    """Громкость по RMS окон 400 мс, тихие окна не учитываются (как гейт в LUFS)."""
    mono = x if x.ndim == 1 else x.mean(axis=1)
    win = int(0.4 * SR)
    if len(mono) < win:
        r = np.sqrt(np.mean(mono ** 2) + 1e-12)
        return 20 * np.log10(r)
    frames = len(mono) // win
    rms = np.sqrt(np.mean(mono[: frames * win].reshape(frames, win) ** 2, axis=1) + 1e-12)
    db = 20 * np.log10(rms)
    gate = max(db.max() - 20.0, -70.0)
    sel = rms[db > gate]
    return 20 * np.log10(np.sqrt(np.mean(sel ** 2)) + 1e-12)


def soft_limit(x, ceiling=0.95, lookahead=0.004, loop=False):
    """Лимитер с упреждением: снижает усиление плавно до пика, без жёсткого клиппинга."""
    peak = np.abs(x) if x.ndim == 1 else np.max(np.abs(x), axis=1)
    g = np.minimum(1.0, ceiling / (peak + 1e-9))
    size = 2 * int(lookahead * SR) + 1
    mode = "wrap" if loop else "nearest"
    g = minimum_filter1d(g, size, mode=mode)
    g = uniform_filter1d(g, size, mode=mode)
    g = uniform_filter1d(g, size, mode=mode)
    g = np.minimum(g, minimum_filter1d(np.minimum(1.0, ceiling / (peak + 1e-9)), 3, mode=mode))
    y = x * (g if x.ndim == 1 else g[:, None])
    return np.clip(y, -0.999, 0.999)


def master(x, target_db=-18.0, loop=False, ceiling=0.85, trim=True):
    x = np.asarray(x, dtype=np.float64)
    # убрать постоянку; у петли фильтруем по кругу, чтобы стык остался непрерывным
    sos = signal.butter(2, 12, "hp", fs=SR, output="sos")
    if loop:
        pad_n = min(len(x), SR)
        xp = np.concatenate([x[-pad_n:], x, x[:pad_n]], axis=0)
        x = signal.sosfiltfilt(sos, xp, axis=0)[pad_n:pad_n + len(x)]
    else:
        x = signal.sosfiltfilt(sos, x, axis=0)
    x = x * 10 ** ((target_db - loudness_db(x)) / 20)
    x = soft_limit(x, ceiling, loop=loop)
    if not loop:
        if trim:
            # Обрезать тишину в конце по окнам 20 мс: всё тише -60 дБ от пика считается тишиной
            env = np.abs(x) if x.ndim == 1 else np.max(np.abs(x), axis=1)
            win = int(0.02 * SR)
            frames = max(1, len(env) // win)
            rms = np.sqrt(np.mean(env[: frames * win].reshape(frames, win) ** 2, axis=1))
            loud = np.nonzero(rms > np.max(env) * 10 ** (-60 / 20))[0]
            if len(loud):
                x = x[: min(len(x), (loud[-1] + 1) * win + int(0.03 * SR))]
        x = fade(x, 0.001, min(0.04, len(x) / SR / 4))
    return x.astype(np.float32)


def save_ogg(path, x, quality=4):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "out.wav")
        wavfile.write(wav, SR, np.asarray(x, dtype=np.float32))
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-i", wav, "-c:a", "libvorbis",
             "-q:a", str(quality), path],
            check=True,
        )


def make_loop(x, xfade=3.0):
    """Бесшовная петля: последние xfade секунд плавно перетекают в начало (равная мощность)."""
    n = int(xfade * SR)
    body = x[: len(x) - n].copy()
    k = np.linspace(0, np.pi / 2, n)
    fin, fout = np.sin(k), np.cos(k)
    if x.ndim == 2:
        fin, fout = fin[:, None], fout[:, None]
    body[:n] = x[:n] * fin + x[len(x) - n:] * fout
    return body


def slow_mod(dur, rng, rate=0.3, depth=1.0):
    """Медленная случайная модуляция 0..1 (порывы ветра, дыхание огня)."""
    n = int(dur * SR)
    pts = max(4, int(dur * rate * 2))
    xs = np.linspace(0, n, pts)
    ys = rng.uniform(0, 1, pts)
    m = np.interp(np.arange(n), xs, ys)
    m = uniform_filter1d(m, max(1, int(SR / rate / 4)))
    return 1 - depth + depth * m
