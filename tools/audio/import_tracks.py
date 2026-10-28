"""Импорт готовых треков (например, сгенерированных /game-music) в игру.

  python3 tools/audio/import_tracks.py              # все файлы из assets/audio/game-music
  python3 tools/audio/import_tracks.py funeral      # только этот id
  python3 tools/audio/import_tracks.py --alt-out=/tmp/alt   # ещё и все остальные варианты (<id>__alt, __v3...) в /tmp/alt

Исходник assets/audio/game-music/<id>.<mp3|wav|ogg|flac|m4a> превращается в assets/audio/music/<id>.ogg
(или stingers/<id>.ogg). У музыки обрезаются вступление и концовка и подбирается место стыка, где
продолжение звучит так же, как начало петли, поэтому петля не слышна. Громкость выравнивается так же,
как у процедурных треков из build.py.
"""

import glob
import json
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import dsp  # noqa: E402
from build import CONFIG, OUT, QUALITY, TARGET  # noqa: E402
from songs import MUSIC, STINGERS  # noqa: E402

SR = dsp.SR
SRC = os.path.join(OUT, "game-music")
EXTS = (".mp3", ".wav", ".ogg", ".flac", ".m4a", ".opus")
# Какой вариант записи идёт в игру: <id>.mp3 — первый, <id>__alt.mp3 — второй, <id>__v3/__v4 — следующие.
# Выбор пользователя 2026-10-28. Треки без "source": "game-music" в data/audio.json играют процедурную версию.
USE = {"farewell": "farewell__alt", "defeat": "defeat__alt", "funeral": "funeral__v4", "combat_undead": "combat_undead__v4",
       "combat": "combat__v3", "tavern": "tavern__v3"}
# Стингеры: генератор делает длинные треки, берём первую фразу не короче min и не длиннее max секунд.
STINGER_LEN = {"omen": (9.0, 12.5), "victory": (2.5, 6.0), "defeat": (4.0, 9.0),
               "level_up": (2.0, 5.0), "quest": (2.0, 5.0), "quest_done": (2.0, 5.0)}
HOP = 0.05  # шаг поиска стыка, с
WIN = 3.0  # сколько секунд после стыка должно совпасть
MIN_LOOP = 50.0  # петля не короче, с
# Треки, где важно развитие: прощание нарастает к полному оркестру, короткая петля его бы потеряла.
# В combat_undead__v3 в конце затухание, зато внутри ровно повторяются 40 с.
MIN_LOOP_FOR = {"farewell": 100.0, "combat_undead__v3": 40.0}
# Cover по моей процедурной петле повторяет её длину и строение, поэтому крутится целиком, от начала до конца.
FULL_LOOP = {"combat__v3", "combat__v4", "combat_undead__v4"}


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


def find_loop(x, min_loop=MIN_LOOP):
    """(a, b) в сэмплах: после b музыка звучит как после a, так что x[a:b] можно крутить по кругу.

    Ищем пару мест, где следующие WIN секунд звучат одинаково (обычно это повтор куплета или темы),
    с петлёй не короче min_loop. Длинная петля чуть лучше, но похожесть важнее.
    """
    end = body_end(x)
    dur = end / SR
    f = features(x[:end])
    w = int(WIN / HOP)
    n = len(f) - w
    a_lo, a_hi = int(2 / HOP), int(dur * 0.5 / HOP)
    min_len = int(min_loop / HOP)
    if n <= a_lo + min_len:
        return None
    win = np.stack([f[i:i + w].ravel() for i in range(n)])
    win /= np.linalg.norm(win, axis=1, keepdims=True) + 1e-9
    a_idx = np.arange(a_lo, min(a_hi, n - min_len))
    sim = win[a_idx] @ win.T
    length = (np.arange(n)[None, :] - a_idx[:, None]) * HOP
    score = np.where(length >= min_loop, sim + 0.0007 * length, -1.0)
    i, j = np.unravel_index(np.argmax(score), score.shape)
    a, b = a_idx[i] * int(HOP * SR), j * int(HOP * SR)
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


def make_music_loop(x, min_loop=MIN_LOOP, xfade=0.35, full=False):
    if full:
        # перекрытие короткое: длинное съело бы долю такта на стыке
        n = int(0.01 * SR)
        (a, b), sim = (0, len(x) - n), 1.0
    else:
        n = int(xfade * SR)
        found = find_loop(x, min_loop)
        if found is None:
            print("    стык не найден, обычная петля с перекрытием")
            return dsp.make_loop(x[: body_end(x)], 3.0), None
        (a, b), sim = found
    out = x[a:b].copy()
    k = np.linspace(0, np.pi / 2, n)[:, None]
    # в начале петли продолжение после b плавно переходит в музыку после a
    out[:n] = x[a:a + n] * np.sin(k) + x[b:b + n] * np.cos(k)
    return out, (a / SR, b / SR, sim)


def cut_stinger(x, min_len, max_len):
    """Первая законченная фраза: режем там, где звук после пика стих на 10 дБ и снова начинает расти.

    Если такого места нет, режем в самом тихом месте между min_len и max_len и гасим подольше.
    """
    if len(x) <= max_len * SR:
        return x
    hop = 0.05
    db = 20 * np.log10(np.convolve(frame_rms(x, hop), np.ones(4) / 4, mode="same") + 1e-9)
    lo, hi = int(min_len / hop), int(max_len / hop)
    peak = np.maximum.accumulate(db)
    cut, fade = None, 0.3
    for i in range(lo, hi):
        if db[i] < peak[i] - 10 and db[i] <= db[i - 1] and db[i] <= db[i + 1]:
            cut = i
            break
    if cut is None:
        cut = lo + int(np.argmin(db[lo:hi]))
        fade = min(1.5, 0.3 * cut * hop)
    n, f = cut * int(hop * SR), int(fade * SR)
    y = x[:n].copy()
    y[-f:] *= np.cos(np.linspace(0, np.pi / 2, f))[:, None] ** 2
    return y


def import_one(path, out_root=None, name=None):
    """Запись -> <out_root>/<music|stingers>/<name>.ogg (name по умолчанию — имя файла записи)."""
    name = name or os.path.splitext(os.path.basename(path))[0]
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
        src = os.path.splitext(os.path.basename(path))[0]
        min_loop = MIN_LOOP_FOR.get(src, MIN_LOOP_FOR.get(base, MIN_LOOP))
        x, info = make_music_loop(x, min_loop, full=src in FULL_LOOP)
        audio = dsp.master(x, target_db=TARGET[section], loop=True)
        where = f"стык {info[0]:.1f}→{info[1]:.1f} с, похожесть {info[2]:.2f}" if info else ""
    else:
        x = cut_stinger(x, *STINGER_LEN.get(base, (2.0, 6.0)))
        audio = dsp.master(x, target_db=TARGET[section], loop=False)
        where = ""
    out = os.path.join(out_root or OUT, folder, f"{name}.ogg")
    dsp.save_ogg(out, audio, QUALITY[section])
    print(f"  {folder}/{name}.ogg  {len(audio) / SR:5.1f} с  {where}")
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    alt_root = next((a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--alt-out=")), None)
    files = {os.path.splitext(os.path.basename(p))[0]: p
             for p in glob.glob(os.path.join(SRC, "*")) if p.lower().endswith(EXTS)}
    if not files:
        print(f"Нет исходников в {os.path.relpath(SRC)}")
        return
    open(os.path.join(SRC, ".gdignore"), "a").close()  # сами исходники Godot не импортирует
    cfg = json.load(open(CONFIG, encoding="utf-8"))
    for base in sorted({n.split("__")[0] for n in files}):
        if args and base not in args:
            continue
        section = "music" if base in MUSIC else "stingers"
        chosen = USE.get(base, base)
        # в игру — выбранный вариант, если трек в audio.json помечен как запись; остальные только для сравнения
        if cfg[section].get(base, {}).get("source") == "game-music" and chosen in files:
            import_one(files[chosen], name=base)
        if alt_root:
            for n in sorted(files):
                if n.split("__")[0] == base and n != chosen:
                    import_one(files[n], alt_root)


if __name__ == "__main__":
    main()
