"""Импорт готовых треков (например, сгенерированных /game-music) в игру.

  python3 tools/audio/import_tracks.py              # все файлы из assets/audio/game-music
  python3 tools/audio/import_tracks.py funeral      # только этот id
  python3 tools/audio/import_tracks.py --alt-out=/tmp/alt   # ещё и запасные варианты <id>__alt в /tmp/alt

Исходник assets/audio/game-music/<id>.<mp3|wav|ogg|flac|m4a> превращается в assets/audio/music/<id>.ogg
(или stingers/<id>.ogg). У музыки обрезаются вступление и концовка и подбирается место стыка, где
продолжение звучит так же, как начало петли, поэтому петля не слышна. Громкость выравнивается так же,
как у процедурных треков из build.py.
"""

import glob
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import dsp  # noqa: E402
from build import OUT, QUALITY, TARGET  # noqa: E402
from songs import MUSIC, STINGERS  # noqa: E402

SR = dsp.SR
SRC = os.path.join(OUT, "game-music")
EXTS = (".mp3", ".wav", ".ogg", ".flac", ".m4a", ".opus")
# Длина стингеров в секундах: генератор делает длинные треки, берём удачное начало такой длины.
STINGER_LEN = {"omen": 10.0, "victory": 6.0, "defeat": 11.0, "level_up": 4.0, "quest": 5.0, "quest_done": 5.0}
HOP = 0.05  # шаг поиска стыка, с
WIN = 3.0  # сколько секунд после стыка должно совпасть


def decode(path):
    raw = subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-i", path, "-f", "f32le", "-ac", "2", "-ar", str(SR), "-"],
        capture_output=True, check=True,
    ).stdout
    return np.frombuffer(raw, np.float32).reshape(-1, 2).astype(np.float64)


def frame_rms(x, hop):
    mono = x.mean(axis=1)
    n = int(hop * SR)
    frames = len(mono) // n
    return np.sqrt(np.mean(mono[: frames * n].reshape(frames, n) ** 2, axis=1) + 1e-12)


def trim_silence(x, thresh_db=-50.0):
    rms = frame_rms(x, 0.02)
    loud = np.nonzero(rms > rms.max() * 10 ** (thresh_db / 20))[0]
    if not len(loud):
        return x
    a = loud[0] * int(0.02 * SR)
    b = (loud[-1] + 1) * int(0.02 * SR)
    return x[a:b]


def body_end(x):
    """Где начинается затухание в конце трека: последний кадр не тише -6 дБ от типичной громкости."""
    rms = frame_rms(x, 0.25)
    level = np.median(rms[len(rms) // 4: 3 * len(rms) // 4])
    ok = np.nonzero(rms >= level * 0.5)[0]
    return (ok[-1] + 1) * int(0.25 * SR) if len(ok) else len(x)


def features(x):
    """Логарифмические энергии 24 полос в кадрах по HOP секунд, нормированные по кадру."""
    mono = x.mean(axis=1)
    hop = int(HOP * SR)
    nfft = 8192
    frames = (len(mono) - nfft) // hop
    idx = np.arange(nfft)[None, :] + hop * np.arange(frames)[:, None]
    spec = np.abs(np.fft.rfft(mono[idx] * np.hanning(nfft), axis=1))
    freqs = np.fft.rfftfreq(nfft, 1 / SR)
    edges = np.geomspace(60, 12000, 25)
    bands = np.stack([spec[:, (freqs >= lo) & (freqs < hi)].sum(axis=1) for lo, hi in zip(edges, edges[1:])], 1)
    f = np.log(bands + 1e-6)
    f -= f.mean(axis=1, keepdims=True)
    return f / (np.linalg.norm(f, axis=1, keepdims=True) + 1e-9)


def find_loop(x):
    """(a, b) в сэмплах: после b музыка звучит как после a, так что x[a:b] можно крутить по кругу."""
    end = body_end(x)
    dur = end / SR
    f = features(x[:end])
    w = int(WIN / HOP)
    n = len(f) - w
    a_lo, a_hi = int(2 / HOP), int(min(25.0, dur * 0.3) / HOP)
    b_lo = int(max(dur * 0.55, (a_hi * HOP) + 20) / HOP)
    if n <= b_lo or a_hi <= a_lo:
        return None
    win = np.stack([f[i:i + w].ravel() for i in range(n)])
    win /= np.linalg.norm(win, axis=1, keepdims=True) + 1e-9
    sim = win[a_lo:a_hi] @ win[b_lo:n].T
    # чем длиннее петля, тем лучше: небольшая премия за длину
    length = (np.arange(b_lo, n)[None, :] - np.arange(a_lo, a_hi)[:, None]) * HOP
    score = sim + 0.002 * length
    i, j = np.unravel_index(np.argmax(score), score.shape)
    a, b = (a_lo + i) * int(HOP * SR), (b_lo + j) * int(HOP * SR)
    return refine(x, a, b), float(sim[i, j])


def refine(x, a, b):
    """Подвинуть b на ±0.15 с, чтобы совпали удары: корреляция огибающей по 5 мс."""
    env = frame_rms(x, 0.005)
    step = int(0.005 * SR)
    ia, ib = a // step, b // step
    w = int(2.0 / 0.005)
    ref = env[ia:ia + w] - env[ia:ia + w].mean()
    best, best_d = -1e9, 0
    for d in range(-30, 31):
        seg = env[ib + d: ib + d + w]
        if len(seg) < w:
            continue
        c = float(np.dot(ref, seg - seg.mean()))
        if c > best:
            best, best_d = c, d
    return a, b + best_d * step


def make_music_loop(x, xfade=0.35):
    found = find_loop(x)
    if found is None:
        print("    стык не найден, обычная петля с перекрытием")
        return dsp.make_loop(x[: body_end(x)], 3.0), None
    (a, b), sim = found
    n = int(xfade * SR)
    out = x[a:b].copy()
    k = np.linspace(0, np.pi / 2, n)[:, None]
    # в начале петли продолжение после b плавно переходит в музыку после a
    out[:n] = x[a:a + n] * np.sin(k) + x[b:b + n] * np.cos(k)
    return out, (a / SR, b / SR, sim)


def cut_stinger(x, target):
    """Начало трека длиной около target: режем в самом тихом месте рядом и плавно гасим."""
    if len(x) <= target * 1.3 * SR:
        return x
    rms = frame_rms(x, 0.05)
    lo, hi = int(target * 0.75 / 0.05), int(min(target * 1.3, len(x) / SR) / 0.05)
    smooth = np.convolve(rms, np.ones(4) / 4, mode="same")
    cut = (lo + int(np.argmin(smooth[lo:hi]))) * int(0.05 * SR)
    fade = int(min(1.2, 0.25 * target) * SR)
    y = x[:cut].copy()
    y[-fade:] *= np.cos(np.linspace(0, np.pi / 2, fade))[:, None] ** 2
    return y


def import_one(path, out_root=None):
    name = os.path.splitext(os.path.basename(path))[0]
    base = name.split("__")[0]
    if base in MUSIC:
        section, folder = "music", "music"
    elif base in STINGERS:
        section, folder = "stingers", "stingers"
    else:
        print(f"  ? {os.path.basename(path)}: неизвестный id, пропускаю")
        return None
    x = trim_silence(decode(path))
    if section == "music":
        x, info = make_music_loop(x)
        audio = dsp.master(x, target_db=TARGET[section], loop=True)
        where = f"стык {info[0]:.1f}→{info[1]:.1f} с, похожесть {info[2]:.2f}" if info else ""
    else:
        x = cut_stinger(x, STINGER_LEN.get(base, 6.0))
        audio = dsp.master(x, target_db=TARGET[section], loop=False)
        where = ""
    out = os.path.join(out_root or OUT, folder, f"{name}.ogg")
    dsp.save_ogg(out, audio, QUALITY[section])
    print(f"  {folder}/{name}.ogg  {len(audio) / SR:5.1f} с  {where}")
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    alt_root = next((a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--alt-out=")), None)
    names = set(args)
    files = sorted(p for p in glob.glob(os.path.join(SRC, "*")) if p.lower().endswith(EXTS))
    if names:
        files = [p for p in files if os.path.splitext(os.path.basename(p))[0].split("__")[0] in names]
    # запасные варианты (<id>__alt) в игру не идут, только в папку для сравнения, если она задана
    alts = [p for p in files if "__" in os.path.basename(p)]
    files = [p for p in files if "__" not in os.path.basename(p)]
    if not files:
        print(f"Нет исходников в {os.path.relpath(SRC)}")
        return
    open(os.path.join(SRC, ".gdignore"), "a").close()  # сами исходники Godot не импортирует
    for p in files:
        import_one(p)
    if alt_root:
        for p in alts:
            import_one(p, alt_root)


if __name__ == "__main__":
    main()
