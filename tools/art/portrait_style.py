"""Портреты для диалогов в одном из стилей, кодом из готового портрета (Gemini или любого другого).

Gemini рисует портреты гладко и ярко, «как нейросеть». Здесь тот же портрет переводится в рисунок:
  engraving — гравюра на меди: тон передают штрихи переменной толщины, они изгибаются по форме лица,
              в тенях перекрёстная штриховка, контуры тушью; тёмно-коричневые чернила на пергаменте;
  medallion — та же гравюра в овальной рамке, снаружи сетка штрихов;
  coloured  — та же гравюра поверх приглушённой акварельной заливки (как дома и персонажи на карте);
  pixel     — пиксель-арт 64×64 на 24 цвета, в масштабе игры.

Запуск: python tools/art/portrait_style.py engraving картинки... --out папка [--size 264] [--lines 44]
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage

INK = np.array([33, 23, 15], float) / 255          # чернила: тёмная умбра
PAPER = np.array([226, 211, 178], float) / 255     # пергамент


def gray(rgb: np.ndarray) -> np.ndarray:
    return rgb @ np.array([0.299, 0.587, 0.114])


def smooth(a: np.ndarray, s: float) -> np.ndarray:
    return ndimage.gaussian_filter(a, s)


def paper(h: int, w: int, seed: int = 3) -> np.ndarray:
    """Пергамент: тёплый тон, крупные пятна и мелкое волокно."""
    rng = np.random.default_rng(seed)
    blot = smooth(rng.standard_normal((h, w)), w / 18)
    blot /= np.abs(blot).max() + 1e-6
    fibre = smooth(rng.standard_normal((h, w)), 0.8) * 0.5 + smooth(rng.standard_normal((h, w)), (0.6, 6)) * 1.2
    fibre /= np.abs(fibre).max() + 1e-6
    tone = 1 + 0.06 * blot + 0.025 * fibre
    yy, xx = np.mgrid[0:h, 0:w]
    r = np.hypot((xx - w / 2) / (w / 2), (yy - h / 2) / (h / 2))
    tone *= 1 - 0.13 * np.clip(r - 0.55, 0, None) ** 1.5      # края потемнее, как у старого листа
    return np.clip(PAPER[None, None] * tone[..., None], 0, 1)


def tone_map(lum: np.ndarray) -> np.ndarray:
    """Светлота для штриха: растянуть по перцентилям, чуть поднять середину, мелочь сгладить."""
    lo, hi = np.percentile(lum, (2, 98))
    t = np.clip((lum - lo) / max(1e-3, hi - lo), 0, 1)
    return smooth(t ** 0.9, lum.shape[1] / 440)


def contours(lum: np.ndarray, s: float) -> np.ndarray:
    """Контур тушью (XDoG): 1 — чернила, 0 — бумага."""
    d = smooth(lum, s) - 0.985 * smooth(lum, s * 1.6)
    e = 1 - np.clip(1 + np.tanh(60 * (d + 0.004)), 0, 1)
    return np.clip(e, 0, 1)


def hatching(t: np.ndarray, period: float, strength: float = 1.0) -> np.ndarray:
    """Штрихи: линии под углом, толщина растёт с темнотой, линии гнутся по крупной форме.
    Второе направление — в полутени, третье — в глубокой тени. 1 — чернила."""
    h, w = t.shape
    yy, xx = np.mgrid[0:h, 0:w].astype(float)
    bend = (smooth(t, w / 40) * 2.2 + smooth(t, w / 110) * 1.5) * period   # изгиб по форме: светлое выпирает
    ink = np.zeros_like(t)
    for ang, start, gain in ((38, 0.92, 1.0), (-52, 0.55, 0.85), (82, 0.28, 0.7)):
        a = np.deg2rad(ang)
        s = (xx * np.cos(a) + yy * np.sin(a) + bend) / period
        dist = np.abs(s - np.floor(s) - 0.5) * 2                # 0 на оси штриха, 1 посередине между
        dark = np.clip((start - t) / start, 0, 1) * gain * strength
        width = np.clip(dark * 1.15, 0, 0.95)
        line = np.clip((width - dist) / 0.18 + 0.5, 0, 1)       # мягкий край штриха
        ink = np.maximum(ink, line * np.clip(dark / 0.08, 0, 1))  # на свету штрих тает, а не обрывается
    return ink


def backdrop(rgb: np.ndarray) -> np.ndarray:
    """Фон за фигурой (0…1, края мягкие): похож на цвет краёв картинки и связан с краем."""
    h, w = rgb.shape[:2]
    soft = ndimage.gaussian_filter(rgb, (w / 150, w / 150, 0))
    border = np.concatenate([soft[0], soft[-1], soft[:, 0], soft[:, -1]])
    c = np.median(border, axis=0)
    lum = gray(rgb)
    detail = smooth(np.abs(lum - smooth(lum, w / 300)), w / 120)  # фон гладкий, фигура в штрихах и складках
    hue = soft - gray(soft)[..., None]                           # оттенок без светлоты: фон светлеет к центру
    near = (np.abs(hue - (c - c.mean())).max(axis=2) < 0.06) & (detail < 0.018) & (np.abs(soft - c).max(axis=2) < 0.3)
    lab, _ = ndimage.label(near)
    top = int(h * 0.7)                                           # низ — всегда фигура (плечи), её тёмная
    edge = set(np.unique(np.concatenate([lab[0], lab[:top, 0], lab[:top, -1]]))) - {0}   # одежда не фон
    m = ndimage.binary_opening(np.isin(lab, list(edge)), iterations=3)
    return np.clip(smooth(m.astype(float), w / 200), 0, 1)


def engraving_ink(rgb: np.ndarray, period: float, strength: float = 1.0) -> np.ndarray:
    lum = gray(rgb)
    t = tone_map(lum)
    h, w = t.shape
    bg = backdrop(rgb)                                           # фон — чистая бумага, лёгкий штрих только по углам
    yy, xx = np.mgrid[0:h, 0:w]
    r = np.hypot((xx - w / 2) / (w / 2), (yy - h * 0.42) / (h / 2))
    t = t * (1 - bg) + np.clip(1.3 - 0.4 * r, 0.72, 1) * bg
    ink = np.maximum(hatching(t, period, strength), contours(lum, period * 0.3) * 0.95)
    deep = np.clip((0.08 - t) / 0.08, 0, 1)                     # самые тёмные места — сплошная тушь
    return np.maximum(ink, deep)


# Рисуем вдвое крупнее и уменьшаем: штрихи выходят ровными, без лесенки.
WORK = 2


def _load(img: Image.Image, w: int) -> np.ndarray:
    return np.asarray(img.convert("RGB").resize((w, w), Image.LANCZOS), float) / 255


def _finish(a: np.ndarray, size: int) -> Image.Image:
    return Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8)).resize((size, size), Image.LANCZOS)


def _ink_on(base: np.ndarray, ink: np.ndarray) -> np.ndarray:
    return base * (1 - ink[..., None]) + INK[None, None] * ink[..., None]


def engraving(img: Image.Image, size: int = 264, lines: float = 50) -> Image.Image:
    """lines — сколько штрихов поперёк картинки. Портрет в окне диалога 120 точек, поэтому штрих нужен
    крупный: около 50 линий, иначе на экране он сливается в серый тон."""
    w = size * WORK
    return _finish(_ink_on(paper(w, w), engraving_ink(_load(img, w), w / lines)), size)


def medallion(img: Image.Image, size: int = 264, lines: float = 50) -> Image.Image:
    """Гравюра в овальной рамке, как портреты в старых книгах: снаружи овала — плотная сетка штрихов."""
    w = h = size * WORK
    out = _ink_on(paper(w, w), engraving_ink(_load(img, w), w / lines))
    yy, xx = np.mgrid[0:h, 0:w].astype(float)
    r = np.hypot((xx - w / 2) / (w * 0.43), (yy - h * 0.5) / (h * 0.47))
    period = w / (lines * 1.15)
    grid = np.maximum(*(np.clip((0.55 - np.abs(((xx * np.cos(a) + yy * np.sin(a)) / period) % 1 - 0.5) * 2) / 0.2, 0, 1)
                        for a in (np.deg2rad(45), np.deg2rad(-45))))
    ring = (np.abs(r - 1.0) < 0.016) | (np.abs(r - 1.045) < 0.009)
    outside = np.clip((r - 1.0) / 0.01, 0, 1)
    ink = np.clip(np.maximum(grid * outside, ring), 0, 1)
    base = out * (1 - outside[..., None]) + paper(h, w, 5) * outside[..., None]
    return _finish(_ink_on(base, ink), size)


def coloured(img: Image.Image, size: int = 264, lines: float = 46) -> Image.Image:
    """Та же гравюра, только штрих легче, а под ним приглушённая акварель."""
    w = size * WORK
    rgb = _load(img, w)
    k = max(3, w // 110)
    wash = ndimage.grey_closing(rgb, size=(k, k, 1))              # тонкие линии тушью убрать, остаётся цвет
    wash = ndimage.gaussian_filter(wash, (w / 250, w / 250, 0))
    g = gray(wash)[..., None]
    wash = g + (wash - g) * 0.85                                 # цвет приглушён, но заметен
    lo, hi = np.percentile(gray(wash), (2, 98))
    wash = np.clip((wash - lo) / max(1e-3, hi - lo) * 0.8 + 0.2, 0, 1)   # акварель светлая: тень дают штрихи
    bg = backdrop(rgb)[..., None]
    wash = wash * (1 - bg) + 0.97 * bg                             # фон — чистая бумага
    ink = engraving_ink(rgb, w / lines, strength=0.6)
    return _finish(_ink_on(paper(w, w) * wash, ink), size)


def pixel(img: Image.Image, size: int = 64, colors: int = 24) -> Image.Image:
    src = img.convert("RGB").filter(ImageFilter.UnsharpMask(radius=img.width / 160, percent=120, threshold=2))
    src = src.resize((size, size), Image.LANCZOS)
    a = np.asarray(src, float) / 255
    g = gray(a)[..., None]
    a = np.clip(g + (a - g) * 0.7, 0, 1)                         # чуть приглушить, как спрайты игры
    lo, hi = np.percentile(gray(a), (1, 99.8))
    a = np.clip((a - lo) / max(1e-3, hi - lo) * 0.94, 0, 1)      # светлые лица не выбеливать
    small = Image.fromarray((a * 255).astype(np.uint8))
    q = small.quantize(colors=colors, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    return q.convert("RGB")


STYLES = {"engraving": engraving, "medallion": medallion, "coloured": coloured, "pixel": pixel}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("style", choices=STYLES)
    ap.add_argument("files", nargs="+")
    ap.add_argument("--out", required=True)
    ap.add_argument("--size", type=int, default=0, help="сторона результата (по умолчанию 264, как у портретов игры; у pixel 64)")
    ap.add_argument("--lines", type=float, default=0, help="штрихов поперёк картинки (гравюры; по умолчанию 50, с акварелью 46)")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    for f in a.files:
        im = Image.open(f)
        kw = {"size": a.size} if a.size else {}
        if a.lines and a.style != "pixel":
            kw["lines"] = a.lines
        res = STYLES[a.style](im, **kw)
        res.save(out / (Path(f).stem + ".png"), optimize=True)
        print(out / (Path(f).stem + ".png"), res.size)


if __name__ == "__main__":
    main()
