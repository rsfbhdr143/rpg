#!/usr/bin/env python3
"""Импорт картинок в игру без ручной нарезки.

Кладёшь картинки, листы спрайтов, папки с кадрами или zip-архивы паков в art/inbox/ и запускаешь:

    python tools/art/import_art.py

Скрипт сам:
  1. распаковывает архивы и находит картинки, кадры-последовательности (walk_0.png, walk_1.png, ...)
     и атласы с JSON (Aseprite, TexturePacker);
  2. убирает однотонный фон (белый, бумажный, «магента») у картинок без прозрачности;
  3. находит сетку кадров в листе (с отступами и без), режет её, раскладывает кадры по анимациям
     (idle, walk, attack, hurt, death, ...) по именам файлов или по строкам листа;
  4. обрезает пустые поля одинаково для всех кадров персонажа, уменьшает слишком большие картинки
     и складывает каждый спрайт в один чистый лист art/sprites/<id>.png;
  5. описывает всё в art/catalog.json (его читает игра);
  6. привязывает спрайты к героям, врагам, клеткам, поверхностям, навыкам и статусам по именам
     (data/sprites.json, синонимы в tools/art/aliases.json). Ручные привязки не трогает;
  7. рисует листы для проверки в art/review/: overview.png (все спрайты с номерами кадров),
     bindings.png (что к чему привязано) и отдельный лист на каждый спрайт.

Если что-то распозналось не так, рядом с картинкой кладётся подсказка <имя>.art.json, например
{"frame": [64, 64], "rows": ["idle", "walk", "attack", "hurt", "death"]}. Все поля описаны в README.

Нужны Python 3.9+ и пакеты pillow, numpy: pip install pillow numpy
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
import tempfile
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

try:
    import numpy as np
    from PIL import Image, ImageDraw, ImageEnhance, ImageFont, ImageSequence
except ImportError:  # pragma: no cover - подсказка для запуска на чистой машине
    sys.exit("Нужны пакеты pillow и numpy: pip install pillow numpy")

IMAGE_EXT = {".png", ".webp", ".gif", ".jpg", ".jpeg", ".bmp", ".tga"}
DEFAULT_FPS = 8.0
MAX_FRAME_SIDE = 512        # больше этого кадры уменьшаются (рисованные картинки из генераторов бывают 1024+)
WRAP = 16                   # больше кадров в строке листа не кладём, длинная анимация переносится
PAD = 1                     # прозрачная рамка вокруг кадра в листе, чтобы соседние кадры не просвечивали
MAX_SHEET_SIDE = 8192
ALPHA_MIN = 8               # пиксель с альфой ниже считается прозрачным
KEY_COLORS = [(255, 0, 255), (0, 255, 0), (0, 255, 255)]

# Названия анимаций: каноническое имя -> слова в именах файлов
ANIM_WORDS = {
    "idle": ["idle", "stand", "standing", "breath", "breathing", "wait", "ready", "stay", "покой", "стойка"],
    "walk": ["walk", "walking", "run", "running", "move", "moving", "jog", "ходьба", "бег", "шаг"],
    "attack": ["attack", "attacking", "atk", "slash", "strike", "melee", "swing", "stab", "thrust", "атака", "удар"],
    "cast": ["cast", "casting", "spellcast", "spell", "magic", "special", "каст", "заклинание", "колдует"],
    "shoot": ["shoot", "shot", "shooting", "bow", "выстрел"],
    "hurt": ["hurt", "hit", "damage", "damaged", "takehit", "pain", "ранен", "урон"],
    "death": ["death", "die", "dying", "dead", "defeat", "ko", "смерть", "гибель"],
    "block": ["defend", "defense", "guard", "parry", "защита"],
    "jump": ["jump", "jumping", "прыжок"],
    "fall": ["fall", "falling"],
    "climb": ["climb", "climbing"],
}
ANIM_LOOKUP = {w: canon for canon, words in ANIM_WORDS.items() for w in words}
NO_LOOP = {"attack", "cast", "shoot", "hurt", "death", "jump", "block"}
DIRECTIONS = {
    "up": "up", "north": "up", "back": "up", "n": "up",
    "down": "down", "south": "down", "front": "down", "s": "down",
    "left": "left", "west": "left", "w": "left",
    "right": "right", "east": "right", "e": "right",
    "ne": "ne", "nw": "nw", "se": "se", "sw": "sw",
}
NOISE_WORDS = {"sheet", "spritesheet", "sprite", "sprites", "anim", "animation", "png", "strip", "frames", "frame", "f"}
KIND_WORDS = {
    "tileset": {"tiles", "tileset", "tilemap", "terrain"},
    "tile": {"tile", "floor", "ground", "wall", "walls"},
    "icon": {"icon", "icons", "ui"},
    "effect": {"fx", "vfx", "effect", "effects", "explosion", "explode", "blast", "projectile",
               "smoke", "spark", "sparks", "impact", "particle", "particles"},
}

# Классический лист LPC (Universal LPC Spritesheet Generator): кадры 64x64, 13 столбцов
LPC_ROWS = (
    [("cast_" + d, 7) for d in ("up", "left", "down", "right")]
    + [("thrust_" + d, 8) for d in ("up", "left", "down", "right")]
    + [("walk_" + d, 9) for d in ("up", "left", "down", "right")]
    + [("attack_" + d, 6) for d in ("up", "left", "down", "right")]
    + [("shoot_" + d, 13) for d in ("up", "left", "down", "right")]
    + [("hurt", 6)]
)

TRANSLIT = dict(zip(
    "абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
    ["a", "b", "v", "g", "d", "e", "e", "zh", "z", "i", "y", "k", "l", "m", "n", "o", "p", "r", "s", "t", "u",
     "f", "h", "ts", "ch", "sh", "sch", "", "y", "", "e", "yu", "ya"],
))


# --- Имена ----------------------------------------------------------------------

def split_words(text: str) -> list[str]:
    """«femaleAdventurer_walk0» -> [female, adventurer, walk0]."""
    text = re.sub(r"([a-zа-яё])([A-ZА-ЯЁ])", r"\1 \2", text)
    text = re.sub(r"([A-ZА-ЯЁ]+)([A-ZА-ЯЁ][a-zа-яё])", r"\1 \2", text)
    return [w for w in re.split(r"[^0-9a-zA-Zа-яА-ЯёЁ]+", text.lower().replace("ё", "е")) if w]


def slug(words: list[str]) -> str:
    out = []
    for w in words:
        out.append("".join(TRANSLIT.get(ch, ch) for ch in w))
    s = re.sub(r"[^0-9a-z]+", "_", "_".join(out)).strip("_")
    return s or "sprite"


@dataclass
class NameInfo:
    base: list[str]          # слова имени без анимации, направления и номера кадра
    anim: str = ""           # каноническое имя анимации, если оно есть в имени файла
    direction: str = ""
    number: int | None = None  # номер кадра в последовательности
    hints: dict = field(default_factory=dict)


def parse_name(stem: str) -> NameInfo:
    words = split_words(stem)
    info = NameInfo(base=[])
    # номер кадра в конце: walk_3, walk3, walk-03
    if words and words[-1].isdigit() and len(words) > 1:
        info.number = int(words.pop())
    for w in words:
        m = re.fullmatch(r"strip(\d+)", w) or re.fullmatch(r"(\d+)f(?:rames?)?", w)
        if m:
            info.hints["count"] = int(m.group(1))
            continue
        m = re.fullmatch(r"(\d+)x(\d+)", w)
        if m:
            info.hints["frame"] = [int(m.group(1)), int(m.group(2))]
            continue
        m = re.fullmatch(r"(\D+?)(\d+)", w)
        root, num = (m.group(1), int(m.group(2))) if m else (w, None)
        if root in ANIM_LOOKUP and not info.anim:
            info.anim = ANIM_LOOKUP[root]
            if num is not None:
                if w == words[-1] and info.number is None:
                    info.number = num        # walk0, walk1 — кадры
                elif num > 1:
                    info.anim += str(num)    # attack2 — вторая атака
            continue
        if w in DIRECTIONS and (info.anim or len(w) > 1):
            info.direction = DIRECTIONS[w]
            continue
        if w in NOISE_WORDS:
            continue
        if num is not None and w == words[-1] and info.number is None and len(words) > 0:
            info.base.append(root)            # flagGreen1 -> flag green, кадр 1
            info.number = num
            continue
        info.base.append(w)
    return info


# --- Маска и фон ----------------------------------------------------------------

def to_rgba(img: Image.Image) -> Image.Image:
    if img.mode == "RGBA":
        return img.copy()
    if img.mode == "P" and "transparency" in img.info:
        return img.convert("RGBA")
    return img.convert("RGBA")


def _dilate(m: np.ndarray) -> np.ndarray:
    out = m.copy()
    out[1:, :] |= m[:-1, :]
    out[:-1, :] |= m[1:, :]
    out[:, 1:] |= m[:, :-1]
    out[:, :-1] |= m[:, 1:]
    return out


def remove_background(arr: np.ndarray, tolerance: int = 48) -> tuple[np.ndarray, bool]:
    """Убирает однотонный фон, связанный с краями картинки. Возвращает (RGBA, был ли фон)."""
    h, w = arr.shape[:2]
    if h < 4 or w < 4:
        return arr, False
    rgb = arr[..., :3].astype(np.int16)
    border = np.concatenate([rgb[0], rgb[-1], rgb[:, 0], rgb[:, -1]])
    bg = np.median(border, axis=0)
    near = np.abs(border - bg).max(axis=1) <= tolerance
    if near.mean() < 0.85:                         # фон должен почти целиком занимать края
        return arr, False
    dist = np.abs(rgb - bg).max(axis=2)
    similar = dist <= tolerance
    region = np.zeros((h, w), bool)
    region[0, :] = similar[0, :]
    region[-1, :] = similar[-1, :]
    region[:, 0] |= similar[:, 0]
    region[:, -1] |= similar[:, -1]
    while True:
        grown = region
        for _ in range(16):
            grown = _dilate(grown) & similar
        if grown.sum() == region.sum():
            break
        region = grown
    share = region.mean()
    if share < 0.10 or share > 0.97:
        return arr, False
    if any(np.abs(bg - np.array(k)).max() <= 16 for k in KEY_COLORS):
        region |= dist <= 8                       # цвет-ключ (магента, зелёный) убираем и внутри фигуры
    out = arr.copy()
    out[..., 3] = np.where(region, 0, out[..., 3])
    # мягкий край: полупрозрачность по удалённости от цвета фона и очистка ореола
    band = _dilate(_dilate(region)) & ~region
    lo, hi = tolerance * 0.5, tolerance * 2.5
    a = np.clip((dist - lo) / (hi - lo), 0.0, 1.0)
    alpha = np.where(band, np.minimum(out[..., 3] / 255.0, a), out[..., 3] / 255.0)
    safe = np.maximum(alpha, 1e-3)[..., None]
    fixed = (rgb - bg * (1.0 - alpha[..., None])) / safe
    out[..., :3] = np.where(band[..., None], np.clip(fixed, 0, 255), out[..., :3]).astype(np.uint8)
    out[..., 3] = (alpha * 255).round().astype(np.uint8)
    return out, True


# --- Поиск сетки ----------------------------------------------------------------

@dataclass
class Axis:
    size: int
    gap: int = 0
    margin: int = 0
    count: int = 1

    def starts(self) -> list[int]:
        return [self.margin + k * (self.size + self.gap) for k in range(self.count)]


def axis_layouts(length: int, min_size: int = 8, max_gap: int = 4) -> list[Axis]:
    out = []
    for gap in range(max_gap + 1):
        for margin in range(max_gap + 1):
            usable = length - 2 * margin + gap
            for size in range(min_size, length - 2 * margin + 1):
                if usable % (size + gap) == 0:
                    out.append(Axis(size, gap, margin, usable // (size + gap)))
    out.sort(key=lambda a: (a.size, a.gap, a.margin))
    return out


def clean_axis(mask: np.ndarray, axis: int) -> Axis | None:
    """Самая мелкая сетка по оси, разрезы которой не задевают рисунок и не дают пустых ячеек внутри."""
    m = mask if axis == 0 else mask.T              # axis 0: режем по столбцам (ширина)
    length = m.shape[1]
    occ = m.sum(axis=0)
    cross = (m[:, 1:] & m[:, :-1]).sum(axis=0)
    cum = np.concatenate([[0], np.cumsum(occ)])
    tol = max(1, int(m.shape[0] * 0.002))
    for lay in axis_layouts(length):
        if lay.count < 2:
            continue
        if lay.margin and (cum[lay.margin] > tol or cum[length] - cum[length - lay.margin] > tol):
            continue
        ok = True
        for s in lay.starts()[1:]:
            if lay.gap:
                if cum[s] - cum[s - lay.gap] > tol:
                    ok = False
                    break
            elif cross[s - 1] > tol:
                ok = False
                break
        if not ok:
            continue
        filled = [cum[s + lay.size] - cum[s] > 0 for s in lay.starts()]
        last = max((i for i, f in enumerate(filled) if f), default=-1)
        if all(filled[: last + 1]):
            return lay
    return None


def periodic_axis(arr: np.ndarray, axis: int) -> dict[int, float]:
    """Насколько резкие перепады цвета на границах клеток каждого размера (для плотных тайлсетов).

    Оценка размера — нижняя четверть силы перепадов на его границах: у настоящей сетки
    перепад есть на всех границах, у половинной — только на каждой второй."""
    a = arr.astype(np.float32)
    rgb = a[..., :3] * (a[..., 3:4] / 255.0)
    px = np.concatenate([rgb, a[..., 3:4]], axis=2)
    if axis == 1:
        px = px.transpose(1, 0, 2)
    energy = np.abs(px[:, 1:] - px[:, :-1]).sum(axis=2).mean(axis=0)
    length = px.shape[1]
    mean = energy.mean() + 1e-6
    return {size: float(np.percentile(energy[size - 1:length - 1:size], 25)) / mean
            for size in range(8, length // 2 + 1) if length % size == 0}


def periodic_grid(arr: np.ndarray, need: float, min_cells: int) -> tuple[int, int] | None:
    sx, sy = periodic_axis(arr, 0), periodic_axis(arr, 1)
    h, w = arr.shape[:2]
    for size in sorted(set(sx) & set(sy)):              # сначала квадратные клетки
        if sx[size] >= need and sy[size] >= need and w // size >= min_cells and h // size >= min_cells:
            return size, size
    fx = next((s for s in sorted(sx) if sx[s] >= need and w // s >= min_cells), None)
    fy = next((s for s in sorted(sy) if sy[s] >= need and h // s >= min_cells), None)
    return (fx, fy) if fx and fy else None


def xy_pieces(mask: np.ndarray) -> list[list[tuple[int, int, int, int]]]:
    """Отдельные рисунки на прозрачном фоне: полосы сверху вниз, в полосе — слева направо."""

    def runs(flags: np.ndarray) -> list[tuple[int, int]]:
        out, start = [], None
        for i, f in enumerate(flags):
            if f and start is None:
                start = i
            elif not f and start is not None:
                out.append((start, i))
                start = None
        if start is not None:
            out.append((start, len(flags)))
        return out

    bands = []
    for y0, y1 in runs(mask.any(axis=1)):
        band = []
        for x0, x1 in runs(mask[y0:y1].any(axis=0)):
            ys = np.nonzero(mask[y0:y1, x0:x1].any(axis=1))[0]
            band.append((x0, y0 + int(ys[0]), x1 - x0, int(ys[-1] - ys[0]) + 1))
        bands.append(band)
    biggest = max((w * h for band in bands for (_, _, w, h) in band), default=0)
    return [[p for p in band if p[2] * p[3] >= biggest * 0.01] for band in bands if band]


@dataclass
class Slice:
    rows: list[list[Image.Image]]     # строки кадров
    layout: str                       # grid | pieces | single | lpc | override
    opaque: bool = False
    cols: int = 1                     # столбцов в исходной сетке (для тайлсетов)


def grid_from_override(img: Image.Image, ov: dict) -> tuple[Axis, Axis] | None:
    w, h = img.size
    if "frame" not in ov and "cols" not in ov and "rows_count" not in ov:
        return None

    def pair(v, default=0):
        if isinstance(v, list):
            return int(v[0]), int(v[1])
        return int(v if v is not None else default), int(v if v is not None else default)

    gx, gy = pair(ov.get("gap"))
    mx, my = pair(ov.get("margin"))
    if "frame" in ov:
        fw, fh = pair(ov["frame"])
    else:
        cols, rows = int(ov.get("cols", 1)), int(ov.get("rows_count", 1))
        fw, fh = (w - 2 * mx - gx * (cols - 1)) // cols, (h - 2 * my - gy * (rows - 1)) // rows
    nx = max(1, (w - 2 * mx + gx) // (fw + gx))
    ny = max(1, (h - 2 * my + gy) // (fh + gy))
    return Axis(fw, gx, mx, nx), Axis(fh, gy, my, ny)


def cut_grid(img: Image.Image, ax: Axis, ay: Axis, keep_empty: bool) -> list[list[Image.Image]]:
    rows = []
    alpha = np.asarray(img)[..., 3]
    for y in ay.starts():
        row = []
        for x in ax.starts():
            cell = alpha[y:y + ay.size, x:x + ax.size]
            row.append(img.crop((x, y, x + ax.size, y + ay.size)) if keep_empty or (cell >= ALPHA_MIN).any() else None)
        if not keep_empty:
            while row and row[-1] is None:
                row.pop()
            row = [c if c is not None else Image.new("RGBA", (ax.size, ay.size)) for c in row]
            if not row:
                continue
        rows.append(row)
    return rows


def slice_image(img: Image.Image, name: NameInfo, ov: dict, tileset_hint: bool, periodic_ok: bool = True) -> Slice:
    """Режет картинку на кадры. Возвращает строки кадров."""
    arr = np.asarray(img)
    w, h = img.size
    opaque = (arr[..., 3] < ALPHA_MIN).mean() < 0.02
    if opaque and not tileset_hint and ov.get("background", "auto") != "keep":
        cleaned, removed = remove_background(arr, int(ov.get("bg_tolerance", 48)))
        if removed:
            img, arr, opaque = Image.fromarray(cleaned, "RGBA"), cleaned, False
    mask = arr[..., 3] >= ALPHA_MIN

    grid = grid_from_override(img, ov)
    if grid:
        ax, ay = grid
        return Slice(cut_grid(img, ax, ay, tileset_hint), "override", opaque, ax.count)

    if w == 832 and h >= 1344 and h % 64 == 0 and not opaque:
        ax, ay = Axis(64, count=13), Axis(64, count=h // 64)
        return Slice(cut_grid(img, ax, ay, True), "lpc", False, 13)

    if "frame" in name.hints:
        fw, fh = name.hints["frame"]
        if 0 < fw <= w and 0 < fh <= h and w % fw == 0 and h % fh == 0:
            ax, ay = Axis(fw, count=w // fw), Axis(fh, count=h // fh)
            return Slice(cut_grid(img, ax, ay, tileset_hint or opaque), "grid", opaque, ax.count)
    if "count" in name.hints and w % name.hints["count"] == 0:
        n = name.hints["count"]
        return Slice(cut_grid(img, Axis(w // n, count=n), Axis(h), False), "grid", opaque, n)

    if not opaque:
        ax, ay = clean_axis(mask, 0), clean_axis(mask, 1)
        # кадры касаются соседей: берём квадратные клетки, если разрезы почти не задевают рисунок
        if ax is None and ay is not None and w % ay.size == 0 and w // ay.size >= 2 and clean_axis_ok(mask, ay.size):
            ax = Axis(ay.size, count=w // ay.size)
        if ay is None and ax is not None and h % ax.size == 0 and h // ax.size >= 2 and clean_axis_ok(mask.T, ax.size):
            ay = Axis(ax.size, count=h // ax.size)
        # полоса анимации без чистых разрезов: квадратные кадры
        strip = bool(name.anim) or "effect" in kind_words(name.base) or "count" in ov
        if ax is None and ay is None and strip:
            if w % h == 0 and w // h >= 2:
                ax = Axis(h, count=w // h)
            elif h % w == 0 and h // w >= 2:
                ay = Axis(w, count=h // w)
        if ax is not None and not merges_pieces(mask, ax, ay or Axis(h)):
            ay = ay or Axis(h)
            return Slice(cut_grid(img, ax, ay, tileset_hint), "grid", False, ax.count)
        # рисунки разложены неровно (часто так выглядят листы из генераторов): режем по пустым промежуткам
        bands = xy_pieces(mask)
        pieces = [p for band in bands for p in band]
        if not tileset_hint and len(pieces) >= (2 if strip else 3):
            biggest = max(p[2] * p[3] for p in pieces)
            if sum(p[2] * p[3] >= biggest * 0.25 for p in pieces) >= 0.6 * len(pieces):
                rows = [[img.crop((x, y, x + pw, y + ph)) for (x, y, pw, ph) in band] for band in bands]
                rows = [r for r in rows if r]
                return Slice(rows, "pieces", False, max(len(r) for r in rows))
        if ax is not None or ay is not None:
            ax, ay = ax or Axis(w), ay or Axis(h)
            return Slice(cut_grid(img, ax, ay, tileset_hint), "grid", False, ax.count)

    # плотный тайлсет без прозрачных зазоров: период по перепадам цвета на границах клеток
    if tileset_hint or (opaque and periodic_ok):
        found = periodic_grid(arr, 1.5 if tileset_hint else 2.0, 2 if tileset_hint else 4)
        if found:
            ax, ay = Axis(found[0], count=w // found[0]), Axis(found[1], count=h // found[1])
            return Slice(cut_grid(img, ax, ay, True), "grid", opaque, ax.count)

    return Slice([[img]], "single", opaque, 1)


def merges_pieces(mask: np.ndarray, ax: Axis, ay: Axis) -> bool:
    """Сетка случайно легла в промежутки между рисунками: в половине клеток и больше по несколько
    отдельных рисунков сравнимой ширины (мелкие куски вроде искр или оружия не считаются)."""
    filled = merged = 0
    for y in ay.starts():
        for x in ax.starts():
            cols = mask[y:y + ay.size, x:x + ax.size].any(axis=0)
            if not cols.any():
                continue
            filled += 1
            edges = np.flatnonzero(np.diff(np.concatenate([[0], cols.astype(np.int8), [0]])))
            widths = edges[1::2] - edges[0::2]
            merged += (widths >= max(widths.max() * 0.5, ax.size * 0.15)).sum() >= 2
    return filled > 0 and merged * 2 >= filled


def clean_axis_ok(mask: np.ndarray, size: int) -> bool:
    """Разрезы через каждые size пикселей по ширине не задевают рисунок (или задевают совсем чуть-чуть)."""
    cross = (mask[:, 1:] & mask[:, :-1]).sum(axis=0)
    cuts = cross[size - 1:mask.shape[1] - 1:size]
    return cuts.size == 0 or cuts.max() <= max(2, mask.shape[0] * 0.05)


def kind_words(words) -> set[str]:
    found = set()
    for kind, vocab in KIND_WORDS.items():
        if vocab & set(words):
            found.add(kind)
    return found


# --- Атласы с JSON (Aseprite, TexturePacker) ------------------------------------

def read_atlas(json_path: Path) -> tuple[Path, list[dict], list[dict]] | None:
    try:
        data = json.loads(json_path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or "frames" not in data or "meta" not in data:
        return None
    meta = data["meta"]
    image = json_path.parent / str(meta.get("image", json_path.stem + ".png"))
    if not image.exists():
        return None
    frames = data["frames"]
    if isinstance(frames, dict):
        frames = [dict(v, filename=k) for k, v in frames.items()]
    return image, frames, list(meta.get("frameTags", []))


def atlas_frames(image: Path, frames: list[dict]) -> list[tuple[str, Image.Image, float]]:
    sheet = to_rgba(Image.open(image))
    out = []
    for f in frames:
        r = f["frame"]
        x, y, w, h = int(r["x"]), int(r["y"]), int(r["w"]), int(r["h"])
        if f.get("rotated"):
            piece = sheet.crop((x, y, x + h, y + w)).rotate(90, expand=True)
        else:
            piece = sheet.crop((x, y, x + w, y + h))
        if f.get("trimmed") and "sourceSize" in f:
            ss, sp = f["sourceSize"], f["spriteSourceSize"]
            full = Image.new("RGBA", (int(ss["w"]), int(ss["h"])))
            full.paste(piece, (int(sp["x"]), int(sp["y"])))
            piece = full
        out.append((str(f.get("filename", "")), piece, float(f.get("duration", 0)) or 0.0))
    return out


# --- Сборка спрайтов ------------------------------------------------------------

@dataclass
class Anim:
    name: str
    frames: list[Image.Image]
    fps: float = DEFAULT_FPS
    loop: bool = True


@dataclass
class Asset:
    id: str
    words: list[str]                  # слова имени (для привязки)
    folder: list[str]                 # слова папок
    kind: str = "sprite"
    anims: list[Anim] = field(default_factory=list)
    tiles: list[Image.Image] | None = None   # тайлсет: кадры по сетке, пустые сохраняются
    cols: int = 0
    sources: list[str] = field(default_factory=list)
    opaque: bool = False
    crop: bool = True
    bind: list[str] = field(default_factory=list)   # явные привязки из подсказки: "units/knight", "locations/forest/wall"
    pixel_box: tuple[int, int] | None = None         # из подсказки: размер в игровых пикселях при пикселизации
    pixel_colors: int = 0
    pixel_tone: tuple[float, float] = (1.0, 1.0)     # из подсказки: [яркость, насыщенность] при пикселизации
    pixel_trim: bool = False                         # из подсказки: срезать светлую бумагу снизу и мелкие обрывки

    def add_anim(self, anim: Anim) -> None:
        names = {a.name for a in self.anims}
        base, n = anim.name, 2
        while anim.name in names:
            anim.name = "%s%d" % (base, n)
            n += 1
        self.anims.append(anim)


def anim_name(info: NameInfo, fallback: str = "idle") -> str:
    name = info.anim or fallback
    return name + ("_" + info.direction if info.direction else "")


def fps_from(ov: dict, durations: list[float]) -> float:
    if "fps" in ov:
        return float(ov["fps"])
    durations = [d for d in durations if d > 0]
    if durations:
        return round(1000.0 / (sum(durations) / len(durations)), 2)
    return DEFAULT_FPS


def load_override(path: Path, folder_override: dict) -> dict:
    ov = dict(folder_override)
    side = path.with_name(path.stem + ".art.json")
    if side.exists():
        try:
            ov.update(json.loads(side.read_text(encoding="utf-8-sig")))
        except ValueError as e:
            print("  ! %s: ошибка в JSON (%s), подсказка пропущена" % (side.name, e))
    return ov


def open_frames(path: Path) -> list[tuple[Image.Image, float]]:
    img = Image.open(path)
    if getattr(img, "n_frames", 1) > 1:   # анимированный GIF / WebP
        return [(to_rgba(f), float(f.info.get("duration", 0))) for f in ImageSequence.Iterator(img)]
    return [(to_rgba(img), 0.0)]


def build_assets(files: list[tuple[Path, str]], log) -> list[Asset]:
    """files: (путь на диске, путь относительно inbox)."""
    by_dir: dict[str, list[tuple[Path, str]]] = {}
    for path, rel in files:
        by_dir.setdefault(str(Path(rel).parent), []).append((path, rel))

    assets: list[Asset] = []
    for folder, items in sorted(by_dir.items()):
        folder_words = [w for part in Path(folder).parts if part != "." for w in split_words(part)]
        folder_name = split_words(Path(folder).name) if folder != "." else []
        folder_ov: dict = {}
        for path, rel in items:
            if path.name == "art.json":
                try:
                    folder_ov = json.loads(path.read_text(encoding="utf-8-sig"))
                except ValueError as e:
                    log("  ! %s: ошибка в JSON (%s), подсказка пропущена" % (rel, e))
        images = [(p, r) for p, r in items if p.suffix.lower() in IMAGE_EXT]
        claimed: set[Path] = set()

        # 1. атласы с JSON (Aseprite, TexturePacker)
        for path, rel in items:
            if path.suffix.lower() != ".json" or path.name.endswith(".art.json") or path.name == "art.json":
                continue
            atlas = read_atlas(path)
            if not atlas:
                continue
            image, frames, tags = atlas
            claimed.add(image.resolve())
            info = parse_name(image.stem)
            words = info.base or folder_name
            asset = Asset(slug(words), words, folder_words, "unit", sources=[rel])
            ov = load_override(image, folder_ov)
            pieces = atlas_frames(image, frames)
            if tags:
                for t in tags:
                    seg = pieces[int(t["from"]):int(t["to"]) + 1]
                    tinfo = parse_name(str(t["name"]))
                    name = anim_name(tinfo, slug(split_words(str(t["name"]))))
                    asset.add_anim(Anim(name, [p[1] for p in seg], fps_from(ov, [p[2] for p in seg]),
                                        tinfo.anim not in NO_LOOP))
            else:
                groups: dict[str, list] = {}
                for fname, img, dur in pieces:
                    finfo = parse_name(Path(fname).stem)
                    groups.setdefault(anim_name(finfo), []).append((finfo.number or 0, img, dur))
                for name, seq in groups.items():
                    seq.sort(key=lambda x: x[0])
                    asset.add_anim(Anim(name, [x[1] for x in seq], fps_from(ov, [x[2] for x in seq]),
                                        anim_base(name) not in NO_LOOP))
            assets.append(asset)
            log("  атлас %s: %s" % (rel, describe(asset)))

        # 2. картинки с анимацией или номером кадра в имени собираются в один спрайт
        groups: dict[str, dict] = {}
        singles = []
        for path, rel in sorted(images, key=lambda x: natural_key(x[1])):
            if path.resolve() in claimed:
                continue
            info = parse_name(path.stem)
            explicit = load_override(path, folder_ov).get("id")
            if explicit:
                # имя задано в подсказке (так делает генератор): «attack», «knocked_down» — не анимация и не направление
                singles.append((path, rel, NameInfo(base=split_words(str(explicit)), hints={"explicit": True})))
                continue
            if info.anim or info.number is not None or info.direction:
                words = info.base or folder_name
                g = groups.setdefault(slug(words), {"words": words, "anims": {}, "sources": []})
                g["anims"].setdefault(anim_name(info), []).append((info.number or 0, path, rel, info))
                g["sources"].append(rel)
            else:
                singles.append((path, rel, info))

        # картинка без анимации в имени («slime.png» рядом со «slime_move.png») — это idle того же спрайта
        rest = []
        for path, rel, info in singles:
            key = slug(info.base or folder_name)
            if key in groups and "idle" not in groups[key]["anims"] and not info.hints.get("explicit"):
                groups[key]["anims"]["idle"] = [(0, path, rel, info)]
                groups[key]["sources"].append(rel)
            else:
                rest.append((path, rel, info))

        for key, g in groups.items():
            kinds = kind_words(g["words"]) | kind_words(folder_words)
            kind = "effect" if "effect" in kinds else "tile" if kinds & {"tile", "tileset"} else "unit"
            asset = Asset(key, g["words"], folder_words, kind, sources=g["sources"], crop=kind != "tile")
            for name in sorted(g["anims"], key=anim_order):
                seq = sorted(g["anims"][name], key=lambda x: x[0])
                ov = load_override(seq[0][1], folder_ov)
                fps = fps_from(ov, [])
                loop = anim_base(name) not in NO_LOOP
                # кадр последовательности — целая картинка; но если файлы — полосы кадров
                # (Attack1.png, Attack2.png), то это разные анимации
                multi = len(seq) > 1
                cut = []
                for _, path, rel, info in seq:
                    for img, dur in open_frames(path):
                        w, h = img.size
                        if multi and w < 2 * h and h < 2 * w:
                            cut.append(([remove_bg_single(img, ov)], dur))
                        else:
                            sl = slice_image(img, info, ov, False, periodic_ok=False)
                            cut.append(([f for row in sl.rows for f in row], dur))
                if multi and any(len(fr) > 1 for fr, _ in cut):
                    for frames, _ in cut:
                        asset.add_anim(Anim(name, frames, fps, loop))
                else:
                    frames = [f for fr, _ in cut for f in fr]
                    asset.add_anim(Anim(name, frames, fps_from(ov, [d for _, d in cut]), loop))
            assets.append(asset)
            log("  %s: %s" % (key, describe(asset)))

        # 3. отдельные листы и картинки
        for path, rel, info in rest:
            ov = load_override(path, folder_ov)
            words = info.base or folder_name or split_words(path.stem)
            own, around = kind_words(words), kind_words(folder_words)
            asset = Asset(slug(words), words, folder_words, sources=[rel])
            asset.bind = [str(b) for b in (ov["bind"] if isinstance(ov.get("bind"), list) else [ov.get("bind")]) if b]
            if ov.get("pixel_box"):
                asset.pixel_box = (int(ov["pixel_box"][0]), int(ov["pixel_box"][1]))
            asset.pixel_colors = int(ov.get("pixel_colors", 0))
            if ov.get("pixel_tone"):
                asset.pixel_tone = (float(ov["pixel_tone"][0]), float(ov["pixel_tone"][1]))
            asset.pixel_trim = bool(ov.get("pixel_trim", False))
            frames = open_frames(path)
            if len(frames) > 1:                       # анимированный GIF / WebP
                asset.kind = "effect" if "effect" in own | around else "unit"
                asset.add_anim(Anim("idle", [remove_bg_single(f, ov) for f, _ in frames],
                                    fps_from(ov, [d for _, d in frames])))
                assets.append(asset)
                log("  %s: %s" % (rel, describe(asset)))
                continue
            tileset = ov.get("kind") == "tileset" or (ov.get("kind") is None and "tileset" in own)
            tile_like = tileset or bool({"tile", "tileset"} & (own | around))
            sl = slice_image(frames[0][0], info, ov, tileset,
                             periodic_ok=not tile_like and path.suffix.lower() not in (".jpg", ".jpeg"))
            if tile_like and sl.layout == "single":
                sl = slice_image(frames[0][0], info, dict(ov, background="keep"), tileset, periodic_ok=False)
            count = sum(len(r) for r in sl.rows)
            if ov.get("kind"):
                asset.kind = str(ov["kind"])
            elif tileset or (sl.opaque and count > 1):
                asset.kind = "tileset"
            elif "effect" in own | around:
                asset.kind = "effect"
            elif "icon" in own | around:
                asset.kind = "icons" if count > 1 else "icon"
            elif tile_like and count == 1:
                asset.kind = "tile"
            elif count == 1:
                asset.kind = "image"
            else:
                asset.kind = "sheet"
            asset.opaque = sl.opaque
            asset.crop = asset.kind not in ("tileset", "tile") and not sl.opaque
            if asset.kind == "tileset":
                asset.tiles = [f for row in sl.rows for f in row]
                asset.cols = sl.cols
                fw, fh = sl.rows[0][0].size
                log("  %s: тайлсет %d×%d клеток по %dx%d" % (rel, sl.cols, len(sl.rows), fw, fh))
                assets.append(asset)
                continue
            fps = fps_from(ov, [])
            if sl.layout == "lpc":
                add_lpc_anims(asset, sl.rows, fps)
            elif ov.get("rows"):
                for i, row in enumerate(sl.rows):
                    if i < len(ov["rows"]) and ov["rows"][i]:
                        nm = str(ov["rows"][i])
                        asset.add_anim(Anim(nm, row, fps, anim_base(nm) not in NO_LOOP))
            elif asset.kind == "effect" or info.anim or ov.get("single_animation"):
                nm = anim_name(info)
                asset.add_anim(Anim(nm, [f for row in sl.rows for f in row], fps, anim_base(nm) not in NO_LOOP))
            elif len(sl.rows) == 1:
                asset.add_anim(Anim("idle", sl.rows[0], fps))
            else:
                for i, row in enumerate(sl.rows):
                    asset.add_anim(Anim("row%d" % i, row, fps))
            assets.append(asset)
            log("  %s: %s, %s" % (rel, asset.kind, describe(asset)))

    # одинаковые имена в разных папках: добавляем имя папки, потом номер
    taken: set[str] = set()
    for a in assets:
        if a.id in taken and a.folder:
            cand = slug(a.folder[-1:] + a.words)
            if cand not in taken:
                a.id = cand
        base, n = a.id, 2
        while a.id in taken:
            a.id = "%s_%d" % (base, n)
            n += 1
        taken.add(a.id)
    return assets


def anim_base(name: str) -> str:
    return name.split("_")[0].rstrip("0123456789")


def anim_order(name: str):
    order = list(ANIM_WORDS)
    base = anim_base(name)
    return (order.index(base) if base in order else len(order), name)


def natural_key(text: str):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", text)]


def describe(asset: Asset) -> str:
    if asset.tiles is not None:
        return "%d клеток" % len(asset.tiles)
    return ", ".join("%s×%d" % (a.name, len(a.frames)) for a in asset.anims)


def remove_bg_single(img: Image.Image, ov: dict) -> Image.Image:
    arr = np.asarray(img)
    if (arr[..., 3] < ALPHA_MIN).mean() >= 0.02 or ov.get("background", "auto") == "keep":
        return img
    cleaned, removed = remove_background(arr, int(ov.get("bg_tolerance", 48)))
    return Image.fromarray(cleaned, "RGBA") if removed else img


def add_lpc_anims(asset: Asset, rows: list[list[Image.Image]], fps: float) -> None:
    asset.kind = "unit"
    by_name = {}
    for i, (name, count) in enumerate(LPC_ROWS):
        if i < len(rows):
            by_name[name] = rows[i][:count]
    for d in ("down", "left", "right", "up"):
        if "walk_" + d in by_name:
            asset.add_anim(Anim("idle_" + d, by_name["walk_" + d][:1], fps))
    for name, frames in by_name.items():
        if name.startswith("walk_"):
            frames = frames[1:]
        base = name.split("_")[0]
        asset.add_anim(Anim(name, frames, fps if base == "walk" else fps * 1.5, base not in NO_LOOP))
    if "hurt" in by_name:
        asset.add_anim(Anim("death", by_name["hurt"], fps, False))
    for i in range(len(LPC_ROWS), len(rows)):
        if any(np.asarray(f)[..., 3].any() for f in rows[i]):
            asset.add_anim(Anim("row%d" % i, rows[i], fps))


# --- Запись листов и каталога ---------------------------------------------------

def bbox_union(frames: list[Image.Image]) -> tuple[int, int, int, int] | None:
    box = None
    for f in frames:
        b = f.getchannel("A").point(lambda v: 255 if v >= ALPHA_MIN else 0).getbbox()
        if b:
            box = b if box is None else (min(box[0], b[0]), min(box[1], b[1]), max(box[2], b[2]), max(box[3], b[3]))
    return box


def resize_rgba(img: Image.Image, size: tuple[int, int], pixel: bool) -> Image.Image:
    if pixel:
        return img.resize(size, Image.NEAREST)
    return img.convert("RGBa").resize(size, Image.LANCZOS).convert("RGBA")


def is_pixel_art(frames: list[Image.Image]) -> bool:
    """Пиксель-арт: мало цветов и почти нет полупрозрачных пикселей."""
    sample = frames[: min(len(frames), 8)]
    colors, semi, total = set(), 0, 0
    for f in sample:
        a = np.asarray(f)
        alpha = a[..., 3]
        semi += int(((alpha > 0) & (alpha < 250)).sum())
        total += int((alpha > 0).sum())
        visible = a[alpha > 0][:, :3]
        colors.update(map(tuple, visible[:: max(1, len(visible) // 4000)].tolist()))
    return total > 0 and semi / total < 0.02 and len(colors) < 256


# --- Пикселизация -------------------------------------------------------------------
# data/sprites.json -> settings.pixelate превращает рисованные картинки в пиксель-арт прямо при импорте:
# уменьшает до размера в «игровых пикселях», сводит к немногим цветам, делает края резкими и обводит фигуры.
# Исходники во входящих не меняются: выключил настройку и запустил импорт — картинки снова рисованные.

PIXELATE_DEFAULTS = {"enabled": False, "unit": 64, "cell": 32, "icon": 32, "colors": 24, "tile_colors": 12,
                     "outline": True}
OUTLINE_COLOR = (24, 18, 14)
PIXEL_ALPHA = 80        # ниже — прозрачный пиксель; не 128, чтобы тонкие ноги скелета и древко не пропадали


def pixelate_options(settings: dict) -> dict | None:
    opts = settings.get("pixelate")
    if not isinstance(opts, dict) or not opts.get("enabled", True):
        return None
    out = dict(PIXELATE_DEFAULTS, **opts)
    out["span"] = max(1, int(settings.get("texture_cells", 1)))
    return out


def pixel_box(kind: str, size: tuple[int, int], opts: dict) -> tuple[int, int] | None:
    """Рамка в игровых пикселях, в которую вписывается кадр. None — этот вид не пикселизуется."""
    w, h = size
    if kind == "portrait":
        return 64, 64
    if kind == "scene":
        return 320, 180
    per_cell = opts["unit"] / 1.25     # юнит в игре ростом 1.25 клетки: столько его пикселей на ширину клетки
    if kind in ("unit", "sheet", "sprite"):
        return round(per_cell * 0.9), opts["unit"]       # рамка юнита в игре 0.9 × 1.25 клетки
    if kind == "image":                                   # дерево, стена-картинка или персонаж одной картинкой
        return round(per_cell), round(per_cell * 1.5)
    if kind in ("icon", "icons"):
        return opts["icon"], opts["icon"]
    if kind == "tile":
        if w >= h * 1.6:                                  # изометрическая плитка: ширина — клетка
            return round(per_cell), round(per_cell)
        return opts["cell"] * opts["span"], opts["cell"] * opts["span"]   # бесшовная текстура на span×span клеток
    if kind == "effect":
        return opts["cell"], opts["cell"]
    return None


def add_outline(a: np.ndarray) -> np.ndarray:
    """Тёмная обводка в пиксель вокруг непрозрачной части (кадр становится на 2 пикселя больше)."""
    a = np.pad(a, ((1, 1), (1, 1), (0, 0)))
    vis = a[..., 3] > 0
    near = np.zeros_like(vis)
    near[1:] |= vis[:-1]
    near[:-1] |= vis[1:]
    near[:, 1:] |= vis[:, :-1]
    near[:, :-1] |= vis[:, 1:]
    a[near & ~vis] = (*OUTLINE_COLOR, 255)
    return a


def islands(mask: np.ndarray) -> list[list[tuple[int, int]]]:
    """Связные куски маски (соседи по стороне)."""
    seen = np.zeros_like(mask)
    out = []
    for y0, x0 in zip(*np.nonzero(mask)):
        if seen[y0, x0]:
            continue
        seen[y0, x0] = True
        stack, part = [(y0, x0)], []
        while stack:
            y, x = stack.pop()
            part.append((y, x))
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= ny < mask.shape[0] and 0 <= nx < mask.shape[1] and mask[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    stack.append((ny, nx))
        out.append(part)
    return out


def trim_paper(rgb: np.ndarray, alpha: np.ndarray, band: float = 0.35, steps: int = 12) -> np.ndarray:
    """Постройки из генератора стоят на лоскуте светлой бумаги: снизу снаружи внутрь снимаем светлые
    блёклые пиксели (до тёмной стены не доходит), потом убираем мелкие оторванные обрывки."""
    vis = alpha > 0
    rows = np.nonzero(vis.any(axis=1))[0]
    if len(rows) == 0:
        return alpha
    c = rgb.astype(float)
    hi, lo = c.max(axis=2), c.min(axis=2)
    light = max(110.0, float(np.percentile(hi[vis], 65)))      # «светлое» — относительно самой картинки
    pale = (hi >= light) & ((hi - lo) <= 0.45 * hi)
    pale[: rows[0] + int((1 - band) * (rows[-1] - rows[0] + 1))] = False
    for _ in range(steps):
        out = ~vis
        edge = np.zeros_like(vis)
        edge[1:] |= out[:-1]
        edge[:-1] |= out[1:]
        edge[:, 1:] |= out[:, :-1]
        edge[:, :-1] |= out[:, 1:]
        edge[0] = edge[-1] = True
        edge[:, 0] = edge[:, -1] = True
        peel = vis & pale & edge
        if not peel.any():
            break
        vis &= ~peel
    parts = islands(vis)
    if parts:
        big = max(len(p) for p in parts)
        for p in parts:
            if len(p) < 0.08 * big:
                ys, xs = zip(*p)
                vis[list(ys), list(xs)] = False
    return np.where(vis, alpha, 0).astype(np.uint8)


def pixelize(pieces: list, size: tuple[int, int], colors: int, outline: bool, seamless: bool,
             soft_alpha: bool, tone: tuple[float, float] = (1.0, 1.0), trim: bool = False) -> list:
    """Кадры -> пиксель-арт одного размера с общей палитрой на все кадры.
    tone — [яркость, насыщенность]: бледные постройки на бумаге можно сделать темнее и сочнее."""
    w, h = size
    brightness, saturation = tone

    def shrink(f: Image.Image) -> Image.Image:
        # штриховка при уменьшении усредняется в серое — чуть поднимаем цвет и контраст
        rgb = ImageEnhance.Contrast(ImageEnhance.Color(f.convert("RGB")).enhance(1.2 * saturation)).enhance(1.1)
        if brightness != 1.0:
            rgb = ImageEnhance.Brightness(rgb).enhance(brightness)
        rgb.putalpha(f.getchannel("A"))
        if not seamless:
            return resize_rgba(rgb, size, False)
        big = Image.new("RGBA", (f.width * 3, f.height * 3))    # 3×3 копии, чтобы края остались бесшовными
        for i in range(3):
            for j in range(3):
                big.paste(rgb, (i * f.width, j * f.height))
        return resize_rgba(big, (w * 3, h * 3), False).crop((w, h, 2 * w, 2 * h))

    small = [None if f is None else np.asarray(shrink(f)) for f in pieces]
    seen = [a[a[..., 3] >= PIXEL_ALPHA][:, :3] for a in small if a is not None]
    pixels = np.concatenate(seen) if seen else np.zeros((0, 3), np.uint8)
    if len(pixels) == 0:
        pixels = np.zeros((1, 3), np.uint8)
    pixels = pixels[:: max(1, len(pixels) // 200000)]
    palette = Image.fromarray(np.ascontiguousarray(pixels.reshape(1, -1, 3))).quantize(
        colors, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    out = []
    for a in small:
        if a is None:
            out.append(None)
            continue
        rgb = Image.fromarray(np.ascontiguousarray(a[..., :3])).quantize(palette=palette, dither=Image.Dither.NONE)
        if soft_alpha:     # облака: четыре ступени прозрачности вместо плавной
            alpha = (np.round(a[..., 3] / 85.0) * 85).astype(np.uint8)
        else:
            alpha = np.where(a[..., 3] >= PIXEL_ALPHA, 255, 0).astype(np.uint8)
        rgb = np.asarray(rgb.convert("RGB"))
        if trim:
            alpha = trim_paper(rgb, alpha)
        px = np.dstack([rgb, alpha])
        out.append(Image.fromarray(add_outline(px) if outline else px, "RGBA"))
    return out


def pack_asset(asset: Asset, out_dir: Path, max_side: int, pixelate: dict | None = None) -> dict | None:
    """Складывает кадры спрайта в один лист: каждая анимация с новой строки, длинные переносятся."""
    if asset.tiles is not None:
        anims, frames, cols = [], asset.tiles, asset.cols
    else:
        anims = [a for a in asset.anims if a.frames]
        if not anims:
            return None
        frames = [f for a in anims for f in a.frames]
        cols = min(max(len(a.frames) for a in anims), WRAP)
    cw = max(f.size[0] for f in frames)
    ch = max(f.size[1] for f in frames)

    def placed(f: Image.Image) -> Image.Image:
        if f.size == (cw, ch):
            return f
        canvas = Image.new("RGBA", (cw, ch))
        canvas.paste(f, ((cw - f.size[0]) // 2, ch - f.size[1]))   # по центру, низом к низу
        return canvas

    cells: list[Image.Image | None] = []      # по порядку индексов кадров; None — пустая ячейка
    starts = []
    if anims:
        for a in anims:
            starts.append(len(cells))
            cells += [placed(f) for f in a.frames]
            cells += [None] * (-len(cells) % cols)
    else:
        cells = [placed(f) for f in frames]
        cells += [None] * (-len(cells) % cols)
    flat = [c for c in cells if c is not None]
    box = bbox_union(flat) if asset.crop else (0, 0, cw, ch)
    if box is None:
        return None
    fw, fh = box[2] - box[0], box[3] - box[1]
    rows = len(cells) // cols
    pixel = is_pixel_art(flat)
    target = None
    if not pixel and pixelate is not None and asset.tiles is None:
        target = asset.pixel_box or pixel_box(asset.kind, (fw, fh), pixelate)
    scale = min(1.0, max_side / max(fw, fh)) if target is None else min(1.0, target[0] / fw, target[1] / fh)
    tw, th = max(1, round(fw * scale)), max(1, round(fh * scale))
    while cols * (tw + 2 * PAD) > MAX_SHEET_SIDE or rows * (th + 2 * PAD) > MAX_SHEET_SIDE:
        scale *= 0.8
        tw, th = max(1, round(fw * scale)), max(1, round(fh * scale))
    pieces = [None if f is None else f.crop(box) for f in cells]
    if target is not None:
        tile = asset.kind == "tile"
        pieces = pixelize(pieces, (tw, th), asset.pixel_colors or pixelate["tile_colors" if tile else "colors"],
                          pixelate["outline"] and asset.kind not in ("tile", "effect", "scene"),
                          tile and tw == th and all((np.asarray(f)[..., 3] >= 250).mean() >= 0.97 for f in flat),
                          asset.kind == "effect", asset.pixel_tone, asset.pixel_trim)
        tw, th = next(f for f in pieces if f is not None).size
        pixel = True
    elif (tw, th) != (fw, fh):
        pieces = [None if f is None else resize_rgba(f, (tw, th), pixel) for f in pieces]
    sheet = Image.new("RGBA", (cols * (tw + 2 * PAD), rows * (th + 2 * PAD)))
    for k, piece in enumerate(pieces):
        if piece is not None:
            sheet.paste(piece, ((k % cols) * (tw + 2 * PAD) + PAD, (k // cols) * (th + 2 * PAD) + PAD))
    out_dir.mkdir(parents=True, exist_ok=True)
    sheet.save(out_dir / (asset.id + ".png"), optimize=True)
    entry = {
        "sheet": "res://art/sprites/%s.png" % asset.id,
        "kind": asset.kind,
        "frame": [tw, th],
        "pad": PAD,
        "cols": cols,
        "count": len(cells),
        "pixel_art": pixel,
        "source": asset.sources,
    }
    if scale != 1.0:
        entry["scale"] = round(scale, 4)
    if all((np.asarray(f)[..., 3] >= 250).mean() >= 0.97 for f in flat):
        entry["opaque"] = True              # сплошная текстура (пол, стена); скруглённые уголки не мешают
    if anims:
        entry["animations"] = {
            a.name: {"start": st, "count": len(a.frames), "fps": a.fps, "loop": a.loop} for a, st in zip(anims, starts)
        }
    return entry


# --- Привязка к игре ------------------------------------------------------------

CATEGORIES = ("units", "tiles", "surfaces", "skills", "statuses")
EXTRA_CATEGORIES = ("portraits", "props", "images", "items")    # только явные привязки из подсказок
KIND_FIT = {
    "units": {"unit": 3, "sheet": 2, "image": 2, "sprite": 3},
    "tiles": {"tile": 3, "image": 2, "tileset": 1},
    "surfaces": {"tile": 2, "effect": 3, "image": 2, "unit": 1, "sheet": 1},
    "skills": {"icon": 3, "image": 2, "effect": 1, "sheet": 1},
    "statuses": {"icon": 3, "image": 2, "effect": 1, "sheet": 1},
}


def game_ids(data_dir: Path) -> dict[str, dict[str, list[list[str]]]]:
    """Все id игры и их имена (как фразы из слов) по категориям."""

    def load(name):
        p = data_dir / name
        return json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}

    out = {c: {} for c in CATEGORIES}
    chars = load("characters.json")
    for cid, d in chars.items():
        out["units"][cid] = [cid.split("_"), split_words(str(d.get("name", "")))]
    for sid, d in load("skills.json").items():
        out["skills"][sid] = [sid.split("_"), split_words(str(d.get("name", "")))]
    st = load("statuses.json").get("statuses", {})
    for sid, d in st.items():
        out["statuses"][sid] = [sid.split("_"), split_words(str(d.get("name", "")))]
    sf = load("surfaces.json").get("surfaces", {})
    for sid, d in sf.items():
        out["surfaces"][sid] = [sid.split("_"), split_words(str(d.get("name", "")))]
    out["tiles"] = {"floor": [["floor"]], "wall": [["wall"]]}
    # свои клетки локаций — только для листа проверки, по словам их не привязываем
    out["locations"] = {"%s/%s" % (loc, t): [] for loc in load("locations.json") for t in ("floor", "wall")}
    return out


def refs_of(value) -> list[str]:
    """Все ссылки привязки: "asset", "asset#3", список вариантов или {"sprite": ...}."""
    if isinstance(value, dict):
        value = value.get("sprite")
    if isinstance(value, list):
        return [str(v) for v in value]
    return [str(value)] if value else []


def all_bindings(bindings: dict):
    """Все привязки: (подпись, значение), включая свои клетки локаций."""
    for cat in CATEGORIES + EXTRA_CATEGORIES:
        for gid, v in bindings.get(cat, {}).items():
            yield "%s/%s" % (cat, gid), v
    for loc, table in bindings.get("locations", {}).items():
        for gid, v in table.items():
            yield "locations/%s/%s" % (loc, gid), v


def ref_asset(ref: str) -> str:
    return str(ref).split("#")[0]


def bind_table(bindings: dict, key: str, create: bool = False) -> tuple[dict | None, str]:
    """Таблица и id для ключа "units/knight" или "locations/forest/wall"."""
    parts = key.split("/")
    if parts[0] == "locations" and len(parts) == 3:
        locs = bindings.setdefault("locations", {}) if create else bindings.get("locations", {})
        table = locs.setdefault(parts[1], {}) if create else locs.get(parts[1])
        return table, parts[2]
    if parts[0] in CATEGORIES + EXTRA_CATEGORIES and len(parts) == 2:
        return (bindings.setdefault(parts[0], {}) if create else bindings.get(parts[0])), parts[1]
    return None, ""


def pop_binding(bindings: dict, key: str) -> None:
    table, gid = bind_table(bindings, key)
    if table is not None:
        table.pop(gid, None)
        if key.startswith("locations/") and not table:
            bindings.get("locations", {}).pop(key.split("/")[1], None)


def display_names(data_dir: Path) -> dict[tuple[str, str], str]:
    """Русские названия для листа привязок."""
    out = {}
    sources = {"units": ("characters.json", None), "skills": ("skills.json", None),
               "statuses": ("statuses.json", "statuses"), "surfaces": ("surfaces.json", "surfaces")}
    for cat, (name, key) in sources.items():
        p = data_dir / name
        table = json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}
        for gid, d in (table.get(key, {}) if key else table).items():
            out[(cat, gid)] = str(d.get("name", gid))
    out.update({("tiles", "floor"): "пол", ("tiles", "wall"): "стена"})
    p = data_dir / "locations.json"
    for loc, d in (json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}).items():
        for t, word in (("floor", "пол"), ("wall", "стена")):
            out[("locations", "%s/%s" % (loc, t))] = "%s: %s" % (d.get("name", loc), word)
    return out


def auto_bind(catalog: dict, words: dict[str, list[str]], ids: dict, aliases: dict, bindings: dict,
              rebind: bool, log, explicit: dict[str, list[str]] | None = None) -> list[str]:
    auto = set(bindings.get("auto", []))
    if rebind:
        for key in list(auto):
            pop_binding(bindings, key)
        auto.clear()
    # убираем авто-привязки к спрайтам, которых больше нет
    for key in list(auto):
        table, gid = bind_table(bindings, key)
        refs = refs_of(table.get(gid)) if table is not None else []
        if not refs or any(ref_asset(r) not in catalog for r in refs):
            pop_binding(bindings, key)
            auto.discard(key)
    made = []
    # явные привязки из подсказок <имя>.art.json ("bind": "units/knight") идут первыми; ручные не трогаем
    for aid in sorted(explicit or {}):
        for key in explicit[aid]:
            table, gid = bind_table(bindings, key, create=True)
            if table is None:
                log("  ! %s: непонятная привязка «%s» в подсказке" % (aid, key))
                continue
            if gid in table and key not in auto:
                continue
            if table.get(gid) != aid:
                table[gid] = aid
                made.append("%s -> %s" % (key, aid))
            auto.add(key)
    for cat in CATEGORIES:
        table = bindings.setdefault(cat, {})
        used = {ref_asset(r) for v in table.values() for r in refs_of(v)}
        cands = []
        for gid, phrases in ids[cat].items():
            if gid in table:
                continue
            all_phrases = [p for p in phrases if p] + [split_words(a) for a in aliases.get(cat, {}).get(gid, [])]
            for aid, entry in catalog.items():
                fit = KIND_FIT[cat].get(entry.get("kind", ""), 0)
                if fit == 0:
                    continue
                name = words[aid]
                for ph in all_phrases:
                    if ph and all(w in name for w in ph):
                        extra = len([w for w in name if w not in ph])
                        cands.append((len(ph) * 100 + fit * 10 - extra, gid, aid))
        cands.sort(key=lambda c: (-c[0], c[1], c[2]))
        for score, gid, aid in cands:
            if gid in table or aid in used:
                continue
            table[gid] = aid
            used.add(aid)
            auto.add("%s/%s" % (cat, gid))
            made.append("%s/%s -> %s" % (cat, gid, aid))
    bindings["auto"] = sorted(auto)
    return made


# --- Листы для проверки ---------------------------------------------------------

def plural(n: int, one: str, few: str, many: str) -> str:
    if n % 10 == 1 and n % 100 != 11:
        word = one
    elif 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14:
        word = few
    else:
        word = many
    return "%d %s" % (n, word)


def _font(size: int):
    for name in ("DejaVuSans.ttf", "arial.ttf", "Arial.ttf", "segoeui.ttf", "LiberationSans-Regular.ttf"):
        for base in ("", "/usr/share/fonts/truetype/dejavu/", "C:/Windows/Fonts/", "/Library/Fonts/",
                     "/System/Library/Fonts/Supplemental/"):
            try:
                return ImageFont.truetype(base + name, size)
            except OSError:
                continue
    try:
        return ImageFont.load_default(size)
    except TypeError:
        return ImageFont.load_default()


def _checker(size: tuple[int, int], cell: int = 8) -> Image.Image:
    img = Image.new("RGBA", size, (58, 58, 66, 255))
    d = ImageDraw.Draw(img)
    for y in range(0, size[1], cell):
        for x in range((y // cell) % 2 * cell, size[0], cell * 2):
            d.rectangle((x, y, x + cell - 1, y + cell - 1), fill=(72, 72, 82, 255))
    return img


def frame_image(sheet: Image.Image, entry: dict, index: int) -> Image.Image:
    fw, fh = entry["frame"]
    pad = entry.get("pad", 0)
    c, r = index % entry["cols"], index // entry["cols"]
    x, y = c * (fw + 2 * pad) + pad, r * (fh + 2 * pad) + pad
    return sheet.crop((x, y, x + fw, y + fh))


def fit_thumb(img: Image.Image, box: int, pixel: bool) -> Image.Image:
    w, h = img.size
    s = box / max(w, h)
    if pixel and s >= 1:
        s = max(1, int(s))
    size = (max(1, round(w * s)), max(1, round(h * s)))
    return img.resize(size, Image.NEAREST if pixel else Image.LANCZOS)


def ref_image(catalog: dict, sheets: dict, ref: str) -> Image.Image | None:
    aid, _, idx = str(ref).partition("#")
    entry = catalog.get(aid)
    if entry is None:
        return None
    if aid not in sheets:
        sheets[aid] = Image.open(Path(entry["_file"]))
    if idx.isdigit():
        index = int(idx)
    else:
        anims = entry.get("animations", {})
        first = anims.get("idle") or next((v for k, v in anims.items() if k.startswith("idle")), None) \
            or next(iter(anims.values()), {"start": 0})
        index = first["start"]
    return frame_image(sheets[aid], entry, index)


def review_asset(entry: dict, aid: str, out: Path) -> None:
    sheet = Image.open(Path(entry["_file"]))
    fw, fh = entry["frame"]
    pixel = entry.get("pixel_art", False)
    cell = 96 if max(fw, fh) > 48 else 64
    cols = entry["cols"]
    labels = {}
    for name, a in entry.get("animations", {}).items():
        labels.setdefault(a["start"] // cols, name)
    rows = (entry["count"] + cols - 1) // cols
    show_rows = min(rows, 48)
    left = 110 if labels else 8
    img = Image.new("RGBA", (left + cols * (cell + 4) + 8, 30 + show_rows * (cell + 18)), (30, 30, 36, 255))
    d = ImageDraw.Draw(img)
    font, small = _font(14), _font(11)
    d.text((8, 6), "%s  (%s, кадр %dx%d)" % (aid, entry["kind"], fw, fh), fill=(240, 220, 140, 255), font=font)
    for r in range(show_rows):
        y = 30 + r * (cell + 18)
        if r in labels:
            d.text((8, y + cell // 2 - 7), labels[r], fill=(200, 220, 255, 255), font=small)
        for c in range(cols):
            k = r * cols + c
            if k >= entry["count"]:
                break
            x = left + c * (cell + 4)
            fr = frame_image(sheet, entry, k)
            if fr.getchannel("A").getbbox() is None and entry["kind"] != "tileset":
                continue
            img.alpha_composite(_checker((cell, cell)), (x, y))
            th = fit_thumb(fr, cell, pixel)
            img.alpha_composite(th, (x + (cell - th.size[0]) // 2, y + (cell - th.size[1]) // 2))
            d.text((x + 2, y + cell + 1), "#%d" % k, fill=(170, 170, 170, 255), font=small)
    img.save(out / ("%s.png" % aid))


def review_overview(catalog: dict, out: Path) -> None:
    items = sorted(catalog.items())
    cols, cell = 8, 112
    rows = max(1, (len(items) + cols - 1) // cols)
    img = Image.new("RGBA", (cols * (cell + 8) + 8, rows * (cell + 34) + 8), (30, 30, 36, 255))
    d = ImageDraw.Draw(img)
    small = _font(11)
    sheets: dict = {}
    for i, (aid, entry) in enumerate(items):
        x, y = 8 + (i % cols) * (cell + 8), 8 + (i // cols) * (cell + 34)
        img.alpha_composite(_checker((cell, cell)), (x, y))
        fr = ref_image(catalog, sheets, aid)
        if fr is not None:
            th = fit_thumb(fr, cell - 4, entry.get("pixel_art", False))
            img.alpha_composite(th, (x + (cell - th.size[0]) // 2, y + (cell - th.size[1]) // 2))
        d.text((x, y + cell + 2), aid[:20], fill=(230, 230, 230, 255), font=small)
        n = len(entry.get("animations", {}))
        info = plural(n, "анимация", "анимации", "анимаций") if n else plural(entry["count"], "кадр", "кадра", "кадров")
        d.text((x, y + cell + 16), "%s, %s" % (entry["kind"], info), fill=(150, 150, 160, 255), font=small)
    img.save(out / "overview.png")


def fit_text(d: ImageDraw.ImageDraw, text: str, font, width: int) -> str:
    """Подпись, укороченная многоточием, чтобы не наезжала на соседнюю."""
    if d.textlength(text, font=font) <= width:
        return text
    while text and d.textlength(text + "…", font=font) > width:
        text = text[:-1]
    return text + "…"


def review_bindings(catalog: dict, bindings: dict, ids: dict, names: dict, out: Path) -> None:
    sections = [("units", "Герои и враги"), ("tiles", "Клетки"), ("locations", "Клетки локаций"),
                ("surfaces", "Поверхности"), ("skills", "Навыки"), ("statuses", "Статусы")]
    sections = [(c, t) for c, t in sections if ids.get(c)]
    cols, cell = 8, 80
    height = 8
    for cat, _ in sections:
        height += 28 + ((len(ids[cat]) + cols - 1) // cols) * (cell + 34)
    img = Image.new("RGBA", (cols * (cell + 40) + 8, height), (30, 30, 36, 255))
    d = ImageDraw.Draw(img)
    font, small = _font(16), _font(11)
    sheets: dict = {}
    y = 8
    for cat, title in sections:
        d.text((8, y), title, fill=(240, 220, 140, 255), font=font)
        y += 28
        for i, gid in enumerate(ids[cat]):
            x, yy = 8 + (i % cols) * (cell + 40), y + (i // cols) * (cell + 34)
            img.alpha_composite(_checker((cell, cell)), (x, yy))
            table, key = bind_table(bindings, "%s/%s" % (cat, gid))
            refs = refs_of((table or {}).get(key))
            ref = refs[0] if refs else None
            fr = ref_image(catalog, sheets, ref) if ref else None
            if fr is not None:
                aid = str(ref).split("#")[0]
                th = fit_thumb(fr, cell - 4, catalog[aid].get("pixel_art", False))
                img.alpha_composite(th, (x + (cell - th.size[0]) // 2, yy + (cell - th.size[1]) // 2))
            else:
                d.line((x, yy, x + cell, yy + cell), fill=(110, 60, 60, 255), width=2)
                d.line((x + cell, yy, x, yy + cell), fill=(110, 60, 60, 255), width=2)
            d.text((x, yy + cell + 2), fit_text(d, names.get((cat, gid), gid), small, cell + 36),
                   fill=(230, 230, 230, 255), font=small)
            d.text((x, yy + cell + 16), fit_text(d, str(ref) if ref else "заглушка", small, cell + 36),
                   fill=(150, 150, 160, 255) if ref else (200, 120, 120, 255), font=small)
        y += ((len(ids[cat]) + cols - 1) // cols) * (cell + 34)
    img.save(out / "bindings.png")


# --- Запуск ---------------------------------------------------------------------

def write_text(path: Path, text: str) -> None:
    """Текстовый файл с переводами строк LF на любой системе (иначе Windows и Linux спорят в git)."""
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def collect(inbox: Path, tmp: Path) -> list[tuple[Path, str]]:
    files = []
    for path in sorted(inbox.rglob("*")):
        rel = path.relative_to(inbox)
        if any(part.startswith(".") or part == "__MACOSX" for part in rel.parts):
            continue
        if path.is_file() and path.suffix.lower() == ".zip":
            dest = tmp / path.stem
            with zipfile.ZipFile(path) as z:
                for member in z.infolist():
                    target = (dest / member.filename).resolve()
                    if not str(target).startswith(str(dest.resolve())):
                        continue                     # защита от путей ../ в архиве
                    if member.is_dir():
                        continue
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with z.open(member) as src, open(target, "wb") as dst:
                        shutil.copyfileobj(src, dst)
            for inner in sorted(dest.rglob("*")):
                irel = inner.relative_to(dest)
                if inner.is_file() and not any(p.startswith(".") or p == "__MACOSX" for p in irel.parts):
                    files.append((inner, (Path(path.stem) / irel).as_posix()))
        elif path.is_file() and (path.suffix.lower() in IMAGE_EXT or path.suffix.lower() == ".json"):
            files.append((path, rel.as_posix()))   # одинаково на Windows и Linux
    return files


def run(root: Path, rebind: bool = False, max_side: int = MAX_FRAME_SIDE, quiet: bool = False) -> dict:
    log = (lambda *a: None) if quiet else print
    inbox, sprites, review = root / "art" / "inbox", root / "art" / "sprites", root / "art" / "review"
    catalog_path, bindings_path = root / "art" / "catalog.json", root / "data" / "sprites.json"
    aliases_path = Path(__file__).with_name("aliases.json")
    inbox.mkdir(parents=True, exist_ok=True)
    bindings = json.loads(bindings_path.read_text(encoding="utf-8")) if bindings_path.exists() else {}
    pixelate = pixelate_options(bindings.get("settings", {}))
    if pixelate:
        log("Пикселизация: юнит %d px, клетка %d px, значок %d px" % (pixelate["unit"], pixelate["cell"], pixelate["icon"]))

    with tempfile.TemporaryDirectory() as tmp:
        files = collect(inbox, Path(tmp))
        log("Найдено файлов: %d" % len(files))
        assets = build_assets(files, log)
        catalog, words, explicit = {}, {}, {}
        for a in assets:
            entry = pack_asset(a, sprites, max_side, pixelate)
            if entry is None:
                log("  ! %s: пустая картинка, пропущена" % a.id)
                continue
            catalog[a.id] = entry
            words[a.id] = list(a.words)
            if a.bind:
                explicit[a.id] = a.bind
    # листы спрайтов, которых больше нет во входящих, удаляем (вместе с файлами импорта Godot)
    if sprites.exists():
        for old in sprites.glob("*.png"):
            if old.stem not in catalog:
                old.unlink()
                old.with_name(old.name + ".import").unlink(missing_ok=True)

    catalog_path.parent.mkdir(parents=True, exist_ok=True)
    write_text(catalog_path, json.dumps({"assets": catalog}, ensure_ascii=False, indent=1) + "\n")

    ids = game_ids(root / "data")
    aliases = json.loads(aliases_path.read_text(encoding="utf-8")) if aliases_path.exists() else {}
    made = auto_bind(catalog, words, ids, aliases, bindings, rebind, log, explicit)
    write_text(bindings_path, json.dumps(bindings, ensure_ascii=False, indent=2) + "\n")

    # проверка: привязки к несуществующим спрайтам
    broken = ["%s -> %s" % (label, r) for label, v in all_bindings(bindings) for r in refs_of(v)
              if ref_asset(r) not in catalog]

    review.mkdir(parents=True, exist_ok=True)
    (review / ".gdignore").touch()
    for old in review.glob("*.png"):
        old.unlink()
    for aid, entry in catalog.items():
        entry["_file"] = str(sprites / (aid + ".png"))
    names = display_names(root / "data")
    review_overview(catalog, review)
    review_bindings(catalog, bindings, ids, names, review)
    for aid, entry in catalog.items():
        review_asset(entry, aid, review)
    for entry in catalog.values():
        entry.pop("_file", None)

    missing = [(cat, gid) for cat in CATEGORIES for gid in ids[cat] if gid not in bindings.get(cat, {})]
    used = {ref_asset(r) for _, v in all_bindings(bindings) for r in refs_of(v)}
    unused = sorted(set(catalog) - used)
    report = ["Спрайтов: %d" % len(catalog), "Новых привязок: %d" % len(made)] + ["  + " + m for m in made]
    if broken:
        report += ["Привязки к несуществующим спрайтам (в игре будет заглушка):"] + ["  ! " + b for b in broken]
    report.append("Без картинки (заглушка): " + (", ".join("%s/%s" % m for m in missing) or "нет"))
    report.append("Спрайты без привязки: " + (", ".join(unused) or "нет"))
    write_text(review / "report.txt", "\n".join(report) + "\n")
    log("\n".join(report))
    log("Проверка: art/review/overview.png и art/review/bindings.png")
    return {"catalog": catalog, "bindings": bindings, "made": made, "missing": missing, "broken": broken,
            "unused": unused}


def main() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="replace")   # консоль Windows без UTF-8 не должна ронять скрипт
        except AttributeError:
            pass
    p = argparse.ArgumentParser(description="Импорт картинок из art/inbox в игру")
    p.add_argument("--root", default=str(Path(__file__).resolve().parents[2]), help="папка проекта Godot")
    p.add_argument("--rebind", action="store_true", help="пересчитать автоматические привязки (ручные не трогает)")
    p.add_argument("--max-size", type=int, default=MAX_FRAME_SIDE, help="наибольшая сторона кадра, пикселей")
    args = p.parse_args()
    run(Path(args.root), args.rebind, args.max_size)


if __name__ == "__main__":
    main()
