"""Дома снаружи — пиксель-арт точно под место дома на карте.

Генератор картинок рисует дома как попало: то на лоскуте земли, то шире своего места, и после растяжки в игре они
сливаются в кашу. Здесь дома строятся по-честному: стены, двускатная крыша, окна, ставни и трубы — как маленькая
3D-сцена в изометрии 2:1 (клетка 32×16, стена 52 px, как у BuildingArt в игре), с буфером глубины и обводкой.
Все дома — один набор: те же материалы и свет; у церкви, кузни, таверны, хижины Ветлы и склепа свои особенности.

Читает дома из карт (data/locations.json, буквы с "building") и для каждого пишет в art/inbox/buildings/ картинку
с привязкой props/bld_<id> (в карте дома: "sprite": "bld_<id>", без "flip"). Двери нарисованы ровно в клетках дверей
карты (на видимых стенах, как is_front в игре), поэтому игра свою дверь поверх рисунка не рисует; окна обходят двери. Картинка не обрезается: ближний угол дома — середина нижнего края.
Буква дома, которая стоит не в углу стен (та же буква у мебели внутри другого дома), домом не считается.
Ещё здесь колокольня (props/bell_tower, место 2×2), колодец (props/well, место 2×2) и доска объявлений
(props/notice_board, клетка; середина клетки — середина нижнего края) в том же стиле, и большая доска для окна
объявлений (images/notice_board, листы — notice_board_pages.json).

    python tools/art/buildings.py                       # все дома из data/locations.json
    python tools/art/buildings.py --maps other.json --preview art/review/village.png
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import zlib
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
WALL_H = 52.0           # как BuildingArt.WALL_H в игре: герой около 40 px
OUTLINE = (18, 12, 10)
LIGHT = {"+u": 1.0, "+v": 0.78, "-u": 0.62, "-v": 0.62, "up": 0.95}
TOWER_H = 150.0         # колокольня — и при церкви, и отдельная: одна высота стен башни

PLASTER = [(184, 167, 132), (196, 186, 162), (180, 152, 112), (170, 160, 140)]
BEAMS = [(74, 50, 32), (62, 42, 28), (84, 58, 36)]
SHUTTERS = [(66, 88, 58), (118, 58, 40), (62, 74, 94), (96, 72, 48)]
ROOF = {
    "shingle": [(128, 72, 46), (108, 62, 42), (96, 84, 72), (134, 84, 52)],
    "thatch": [(168, 136, 76), (156, 124, 70)],
    "slate": [(78, 82, 96), (70, 74, 86)],
    "moss": [(118, 112, 62)],
    "hide": [(128, 96, 66)],
}
STONE = (138, 132, 120)
LOG = (122, 86, 54)


def seed_of(text: str) -> int:
    return zlib.crc32(text.encode("utf-8")) & 0x7FFFFFFF


def noise(a, b, seed: int):
    """Детерминированный шум 0..1 по целым координатам (массивы numpy)."""
    a = np.asarray(a, dtype=np.int64)
    b = np.asarray(b, dtype=np.int64)
    h = (a * 73856093) ^ (b * 19349663) ^ (seed * 83492791)
    h = (h ^ (h >> 13)) * 1274126177
    return ((h ^ (h >> 16)) & 0xFFFF) / 65535.0


def mix(c1, c2, t):
    t = np.asarray(t, dtype=float)[..., None]
    return np.asarray(c1, float) * (1 - t) + np.asarray(c2, float) * t


def shade(rgb, k):
    k = np.asarray(k, dtype=float)
    if k.ndim:
        k = k[..., None]
    return np.clip(np.asarray(rgb, float) * k, 0, 255)


def full(n, rgb):
    return np.tile(np.asarray(rgb, float), (n, 1))


# --- Сцена: многоугольники в 3D, проекция 2:1, буфер глубины ------------------------------------------------

class Scene:
    """Точка (u, v, z): u, v — клетки от дальнего угла дома, z — пиксели вверх. Экран: x = 16(u - v), y = 8(u + v) - z.
    Глубина — шаг вдоль взгляда (1, 1, 16): больше — ближе к камере."""

    def __init__(self, w: int, h: int, oy: int, ox: float):
        self.w, self.h = w, h
        self.ox, self.oy = ox, oy
        self.rgb = np.zeros((h, w, 3), float)
        self.depth = np.full((h, w), -1e9)
        self.ids = np.zeros((h, w), np.int32)
        ys, xs = np.mgrid[0:h, 0:w]
        X = xs + 0.5 - ox
        Y = ys + 0.5 - oy
        self.u0 = (Y / 8 + X / 16) / 2
        self.v0 = (Y / 8 - X / 16) / 2
        self.next_id = 1

    def screen(self, p):
        u, v, z = p
        return (self.ox + 16 * (u - v), self.oy + 8 * (u + v) - z)

    def poly(self, verts, shader, light: float = 1.0) -> int:
        """Плоский многоугольник; shader(u, v, z) -> цвета (N, 3)."""
        pts = [self.screen(p) for p in verts]
        mask_img = Image.new("L", (self.w, self.h), 0)
        ImageDraw.Draw(mask_img).polygon(pts, fill=1, outline=1)
        mask = np.asarray(mask_img).astype(bool)
        if not mask.any():
            return 0
        P = np.asarray(verts, float)
        n = np.zeros(3)
        for i in range(len(P)):                      # нормаль по Ньюэллу
            a, b = P[i], P[(i + 1) % len(P)]
            n += [(a[1] - b[1]) * (a[2] + b[2]), (a[2] - b[2]) * (a[0] + b[0]), (a[0] - b[0]) * (a[1] + b[1])]
        den = n[0] + n[1] + 16 * n[2]
        if abs(den) < 1e-9:
            return 0
        c = n @ P[0]
        u0, v0 = self.u0[mask], self.v0[mask]
        a = (c - n[0] * u0 - n[1] * v0) / den
        near = a > self.depth[mask]
        if not near.any():
            return 0
        pid = self.next_id
        self.next_id += 1
        idx = np.nonzero(mask)
        sel = (idx[0][near], idx[1][near])
        aa = a[near]
        col = shader(u0[near] + aa, v0[near] + aa, 16 * aa)
        self.rgb[sel] = shade(col, light)
        self.depth[sel] = aa
        self.ids[sel] = pid
        return pid

    def image(self, colors: int = 40) -> Image.Image:
        vis = self.ids > 0
        rgb = self.rgb.copy()
        # линия там, где ближняя часть закрывает дальнюю (свес крыши над стеной, труба над скатом)
        edge = np.zeros_like(vis)
        for dy, dx in ((0, 1), (1, 0), (0, -1), (-1, 0)):
            ids_n = np.roll(np.roll(self.ids, dy, 0), dx, 1)
            dep_n = np.roll(np.roll(self.depth, dy, 0), dx, 1)
            edge |= vis & (ids_n > 0) & (ids_n != self.ids) & (dep_n > self.depth + 0.04)
        rgb[edge] = rgb[edge] * 0.35 + np.asarray(OUTLINE) * 0.65
        a = np.dstack([np.clip(rgb, 0, 255).astype(np.uint8), np.where(vis, 255, 0).astype(np.uint8)])
        img = Image.fromarray(a, "RGBA")
        q = img.convert("RGB").quantize(colors, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
        out = np.dstack([np.asarray(q.convert("RGB")), a[..., 3]])
        return Image.fromarray(outline(out), "RGBA")


def outline(a: np.ndarray) -> np.ndarray:
    vis = a[..., 3] > 0
    near = np.zeros_like(vis)
    near[1:] |= vis[:-1]
    near[:-1] |= vis[1:]
    near[:, 1:] |= vis[:, :-1]
    near[:, :-1] |= vis[:, 1:]
    a = a.copy()
    a[near & ~vis] = (*OUTLINE, 255)
    return a


# --- Материалы стен: s — вдоль стены в клетках, z — высота в пикселях -----------------------------------------

@dataclass
class Look:
    wall: str = "timber"          # timber | plaster | log | stone | sticks
    roof: str = "shingle"         # shingle | thatch | slate | moss | hide
    plaster: tuple = PLASTER[0]
    beam: tuple = BEAMS[0]
    shutter: tuple = SHUTTERS[0]
    roof_col: tuple = ROOF["shingle"][0]
    wall_h: float = WALL_H
    pitch: float = 14.0           # подъём крыши на клетку (px)
    eave: float = 0.25            # свес крыши в клетках (шире — картинка шире места дома больше чем на 15%)
    floors: int = 1
    chimney: bool = False
    braces: bool = True
    lit: float = 0.6              # доля светящихся окон
    win: str = "shutter"          # shutter | arch (церковь) | none
    flowers: bool = False         # ящики с цветами под окнами
    cross_ridge: bool = False     # конёк поперёк длинной стороны (почти квадратные дома — для разнообразия)
    seed: int = 0
    extras: list = field(default_factory=list)


def wall_shader(look: Look, axis: str, length: float):
    """axis "u" — стена вдоль u (грань +v), "v" — вдоль v (грань +u); length — длина стены в клетках.
    Сверху тень от свеса крыши, снизу стена темнее от земли."""
    H = look.wall_h
    raw = _wall_shader(look, axis, length)

    def f(u, v, z):
        col = raw(u, v, z)
        k = np.where(z > H - 7, 0.7, 1.0) * np.clip(0.84 + z * 0.016, 0.84, 1.0)
        return shade(col, k)
    return f


def _wall_shader(look: Look, axis: str, length: float):
    H = look.wall_h

    def f(u, v, z):
        s = u if axis == "u" else v
        n = len(s)
        kind = look.wall
        if kind == "stone":
            return stone(s, z, look.seed, STONE)
        if kind == "log":
            row = np.floor(z / 6)
            fz = z / 6 - row
            col = shade(LOG, 0.78 + 0.32 * np.sin(fz * np.pi) + 0.06 * (noise(row, np.floor(s * 6), look.seed) - 0.5))
            col[fz < 0.17] = shade(LOG, 0.42)
            # торцы брёвен на ближнем углу: светлые срезы через ряд
            end = (np.abs(s - length) * 18 < 3.2) & (row % 2 == 0) & (fz > 0.15)
            col[end] = (176, 136, 92)
            col[end & (np.abs(fz - 0.55) < 0.18) & (np.abs(s - length) * 18 < 1.4)] = (128, 92, 58)
            col[z < 6] = shade(STONE, 0.7)
            return col
        if kind == "sticks":
            stick = np.floor(s * 32 / 3)
            fs = s * 32 / 3 - stick
            col = shade((112, 92, 64), 0.75 + 0.35 * np.sin(fs * np.pi) * (0.8 + 0.4 * noise(stick, 0, look.seed)))
            col[fs < 0.2] = (40, 30, 22)
            return col
        # штукатурка с балками (фахверк) или беленая стена
        col = shade(look.plaster, 0.96 + 0.08 * noise(np.floor(s * 20), np.floor(z / 3), look.seed))
        plinth = z < 6
        col[plinth] = stone(s[plinth], z[plinth], look.seed + 1, (118, 110, 98))
        beam = np.asarray(look.beam, float)
        storey = H / look.floors
        rails = [6.0] + [storey * k for k in range(1, look.floors)] + [H - 3.0]
        is_beam = np.zeros(n, bool)
        for r in rails:
            is_beam |= (z >= r) & (z < r + 2.5)
        post = np.abs(s - np.round(s)) * 18 < 1.1
        if look.wall == "plaster":
            post = (np.abs(s - np.round(s)) * 18 < 1.1) & ((np.round(s) == 0) | (np.round(s) >= length))
        is_beam |= post & (z >= 6)
        if look.braces and look.wall == "timber":
            cell = np.floor(s)
            fs = s - cell
            for k in range(look.floors):
                z0, z1 = 6 + storey * k, storey * (k + 1) - 3
                inside = (z >= z0) & (z < z1)
                up = (noise(cell, k, look.seed) > 0.5)
                line = np.where(up, z0 + fs * (z1 - z0), z1 - fs * (z1 - z0))
                is_beam |= inside & (np.abs(z - line) < 1.3) & (noise(cell, k + 7, look.seed) > 0.45)
        col[is_beam] = beam
        return col
    return f


def stone(s, z, seed, base):
    """Кладка: ряды по 7 px, камни по трети клетки вразбежку, у земли кое-где мох."""
    row = np.floor(z / 7)
    off = (row % 2) * 0.5
    blk = np.floor(s * 3 + off)
    fz = z / 7 - row
    fs = s * 3 + off - blk
    n = noise(blk, row, seed)
    col = shade(base, 0.7 + 0.42 * n)
    col[fz > 0.72] = shade(base, 0.6 + 0.3 * n[fz > 0.72])      # нижняя кромка камня темнее
    mossy = (z < 16) & (noise(blk, row, seed + 17) > 0.72)
    col[mossy] = shade((96, 112, 70), 0.8 + 0.3 * n[mossy])
    mortar = (fz < 0.14) | (fs < 0.07)
    col[mortar] = shade(base, 0.38)
    return col


def boards_shader(color, seed):
    """Фронтон из вертикальных досок."""
    def f(u, v, z):
        s = u - v
        b = np.floor(s * 5)
        col = shade(color, 0.85 + 0.25 * noise(b, 0, seed))
        col[(s * 5 - b) < 0.18] = shade(color, 0.5)
        return col
    return f


def roof_shader(look: Look, ridge_z: float, axis: str):
    """Скат крыши: ряды по высоте падения от конька; axis — вдоль чего конёк."""
    kind, base, seed = look.roof, look.roof_col, look.seed

    def f(u, v, z):
        a = u if axis == "u" else v
        drop = ridge_z - z
        if kind in ("thatch", "moss"):
            row = np.floor(drop / 5)
            fr = drop / 5 - row
            straw = noise(np.floor(a * 14 + row * 0.37), row, seed)
            col = shade(base, 0.66 + 0.36 * fr + 0.36 * (straw - 0.5))
            col[fr > 0.8] = shade(base, 0.5)
            if kind == "moss":
                patch = noise(np.floor(a * 3), np.floor(drop / 9), seed + 3)
                fine = noise(np.floor(a * 24), np.floor(drop / 2), seed + 5)
                green = (patch > 0.45) & (fine > 0.25)
                col[green] = shade((84, 108, 52), 0.8 + 0.35 * fine[green])
            col[drop < 3] = shade(base, 0.55)          # конёк
            return col
        if kind == "hide":
            patch = noise(np.floor(a * 2.5), np.floor(drop / 10), seed)
            tones = np.asarray([(128, 96, 66), (150, 124, 88), (96, 74, 56), (118, 104, 80)], float)
            col = tones[(patch * 4).astype(int) % 4] * (0.85 + 0.25 * noise(np.floor(a * 10), np.floor(drop / 3), seed))[:, None]
            seam = (np.abs(a * 2.5 - np.round(a * 2.5)) < 0.05) | (np.abs(drop / 10 - np.round(drop / 10)) < 0.08)
            col[seam] = shade(base, 0.45)
            return col
        rh = 4.0 if kind == "shingle" else 5.0
        row = np.floor(drop / rh)
        off = (row % 2) * 0.5
        width = 0.28 if kind == "shingle" else 0.36
        tile = np.floor(a / width + off)
        fr = drop / rh - row
        ft = a / width + off - tile
        col = shade(base, 0.82 + 0.26 * noise(tile, row, seed) + 0.12 * (1 - fr))
        col[(fr > 0.8) | (ft < 0.07)] = shade(base, 0.5)
        col[drop < 2.5] = shade(base, 0.6)
        return col
    return f


def flat(color):
    return lambda u, v, z: full(len(u), color)


# --- Дом ---------------------------------------------------------------------------------------------------

def footprint_scene(w: float, h: float, top: float) -> Scene:
    """Холст под место w×h: ближний угол (w, h, 0) — на нижнем крае, середина ромба места — посередине по ширине
    (так рисунок ставит игра: _draw_shell); top — запас высоты в пикселях."""
    cw = int((w + h) * 16 + 80)
    oy = int(math.ceil(top)) + 4
    ch = int(oy + 8 * (w + h) + 2)
    return Scene(cw, ch, oy, cw / 2 - 8 * (w - h))


def house_scene(w: int, h: int, look: Look, extra_top: float = 0.0) -> Scene:
    return footprint_scene(w, h, look.wall_h + min(w, h) / 2 * look.pitch + 30 + extra_top)


def tighten(img: Image.Image) -> Image.Image:
    """Срезать пустое сверху и поровну по бокам: низ и середина (точка опоры) остаются на месте."""
    a = np.asarray(img)[..., 3] > 0
    if not a.any():
        return img
    rows = np.nonzero(a.any(axis=1))[0]
    cols = np.nonzero(a.any(axis=0))[0]
    m = max(0, min(cols[0], img.width - 1 - cols[-1]) - 1)
    return img.crop((m, max(0, rows[0] - 1), img.width - m, img.height))


def build_house(sc: Scene, w: int, h: int, look: Look, doors: list[tuple[int, int]]):
    H = look.wall_h
    along_u = (w >= h) != (look.cross_ridge and abs(w - h) <= 1)
    A, B = (w, h) if along_u else (h, w)     # A — вдоль конька, B — поперёк
    rise = B / 2 * look.pitch
    ridge_z = H + rise
    e = look.eave
    k = look.pitch

    def P(a, b, z):
        return (a, b, z) if along_u else (b, a, z)

    # стены: видимые грани +v (вдоль u) и +u (вдоль v)
    sc.poly([(0, h, 0), (w, h, 0), (w, h, H), (0, h, H)], wall_shader(look, "u", w), LIGHT["+v"])
    sc.poly([(w, 0, 0), (w, h, 0), (w, h, H), (w, 0, H)], wall_shader(look, "v", h), LIGHT["+u"])
    # фронтон на ближнем торце конька
    gable_col = (96, 70, 46) if look.wall in ("timber", "plaster", "log", "sticks") else None
    gable = [P(A, 0, H), P(A, B, H), P(A, B / 2, ridge_z)]
    face = "+u" if along_u else "+v"
    if gable_col is None:
        sc.poly(gable, lambda u, v, z: stone(v if along_u else u, z, look.seed, STONE), LIGHT[face])
    else:
        sc.poly(gable, boards_shader(gable_col, look.seed), LIGHT[face])
    # скаты: дальний виден сверху, ближний закрывает стену; свес ниже верха стены
    low = H - e * k
    roof = roof_shader(look, ridge_z, "u" if along_u else "v")
    sc.poly([P(-e, -e, low), P(A + e, -e, low), P(A + e, B / 2, ridge_z), P(-e, B / 2, ridge_z)], roof, 0.72)
    near_face = "+v" if along_u else "+u"
    sc.poly([P(-e, B / 2, ridge_z), P(A + e, B / 2, ridge_z), P(A + e, B + e, low), P(-e, B + e, low)],
            roof, 0.98 if near_face == "+v" else 1.08)
    # толщина крыши: доска по краю свеса и по торцу
    t = 3.0
    edge = shade(look.roof_col, 0.45)
    sc.poly([P(-e, B + e, low), P(A + e, B + e, low), P(A + e, B + e, low - t), P(-e, B + e, low - t)], flat(edge))
    sc.poly([P(A + e, -e, low), P(A + e, B / 2, ridge_z), P(A + e, B / 2, ridge_z - t), P(A + e, -e, low - t)],
            flat(shade(edge, 0.9)))
    sc.poly([P(A + e, B / 2, ridge_z), P(A + e, B + e, low), P(A + e, B + e, low - t), P(A + e, B / 2, ridge_z - t)],
            flat(edge))
    if look.chimney:
        rng = noise(3, 4, look.seed)
        ca = A * (0.25 + 0.5 * rng)
        cb = B / 2 - 0.9
        box(sc, P(ca, cb, H), P(ca + 0.7, cb + 0.7, ridge_z + 14), lambda u, v, z: stone(u + v, z, look.seed + 9, (112, 104, 96)))
    windows(sc, w, h, look, doors)
    doors_on_walls(sc, w, h, look, doors)
    return {"apex": P(A, B / 2, ridge_z), "ridge_z": ridge_z, "along_u": along_u}


def box(sc: Scene, p0, p1, shader, top_col=None):
    (u0, v0, z0), (u1, v1, z1) = p0, p1
    u0, u1 = sorted((u0, u1))
    v0, v1 = sorted((v0, v1))
    sc.poly([(u0, v1, z0), (u1, v1, z0), (u1, v1, z1), (u0, v1, z1)], shader, LIGHT["+v"])
    sc.poly([(u1, v0, z0), (u1, v1, z0), (u1, v1, z1), (u1, v0, z1)], shader, LIGHT["+u"])
    sc.poly([(u0, v0, z1), (u1, v0, z1), (u1, v1, z1), (u0, v1, z1)], shader if top_col is None else flat(top_col), LIGHT["up"])


def windows(sc: Scene, w: int, h: int, look: Look, doors: list[tuple[int, int]]):
    """Окна со ставнями на двух видимых стенах, мимо дверей и углов."""
    H = look.wall_h
    storey = H / look.floors
    door_u = {x for x, y in doors if y == h - 1}
    door_v = {y for x, y in doors if x == w - 1}
    for axis, length, busy in (("u", w, door_u), ("v", h, door_v)):
        start = 1 + int(noise(len(busy), 5, look.seed + (axis == "v")) > 0.5)
        for i in range(start, length - 1, 2):
            if busy & {i - 1, i, i + 1}:
                continue
            for k in range(look.floors):
                z0 = storey * k + (storey - 3) * 0.42
                lit = noise(i, k + (axis == "v") * 9, look.seed + 2) < look.lit
                if look.win == "arch":
                    arch_window(sc, axis, w, h, i + 0.5, look)
                elif look.win == "shutter":
                    window(sc, axis, w, h, i + 0.5, z0, look, lit)


def window(sc: Scene, axis: str, w: int, h: int, mid: float, z0: float, look: Look, lit: bool):
    def at(s, z, out=0.02):
        return (s, h + out, z) if axis == "u" else (w + out, s, z)
    face = LIGHT["+v" if axis == "u" else "+u"]
    hw, hz = 0.2, 13.0
    frame = shade(look.beam, 0.9)
    sc.poly([at(mid - hw - 0.05, z0 - 2), at(mid + hw + 0.05, z0 - 2), at(mid + hw + 0.05, z0 + hz + 1.5),
             at(mid - hw - 0.05, z0 + hz + 1.5)], flat(frame), face)
    glass_lit, glass_dark = (240, 184, 92), (40, 46, 62)

    def glass(u, v, z):
        s = u if axis == "u" else v
        col = full(len(u), glass_lit if lit else glass_dark)
        if lit:
            col = mix(glass_lit, (255, 222, 150), np.clip((z - z0) / hz, 0, 1))
        cross = (np.abs(s - mid) < 0.035) | (np.abs(z - (z0 + hz * 0.55)) < 0.8)
        col[cross] = frame
        return col
    sc.poly([at(mid - hw, z0, 0.04), at(mid + hw, z0, 0.04), at(mid + hw, z0 + hz, 0.04), at(mid - hw, z0 + hz, 0.04)],
            glass, face if not lit else 1.0)
    for side in (-1, 1):
        a0 = mid + side * (hw + 0.05)
        a1 = mid + side * (hw + 0.22)
        def shut(u, v, z, a0=a0, a1=a1):
            s = u if axis == "u" else v
            col = shade(look.shutter, 0.9 + 0.15 * noise(np.floor((s - min(a0, a1)) * 30), 0, look.seed))
            col[np.abs(z - (z0 + hz * 0.5)) < 0.7] = shade(look.shutter, 0.55)
            return col
        sc.poly([at(min(a0, a1), z0 - 1, 0.05), at(max(a0, a1), z0 - 1, 0.05), at(max(a0, a1), z0 + hz + 1, 0.05),
                 at(min(a0, a1), z0 + hz + 1, 0.05)], shut, face)
    sill = flat(shade(look.beam, 1.3))
    if look.flowers and k_flowers(mid, z0, look):
        petals = [(196, 60, 52), (224, 186, 70), (210, 120, 150)]

        def sill(u, v, z, petals=petals):
            s = u if axis == "u" else v
            col = full(len(u), shade(look.beam, 1.1))
            dots = noise(np.floor(s * 20), np.floor(z), look.seed + 6)
            top = z > z0 - 2.4
            col[top & (dots > 0.45)] = (70, 104, 52)
            pick = (dots * 3).astype(int) % 3
            bloom = top & (dots > 0.8)
            col[bloom] = np.asarray(petals, float)[pick[bloom]]
            return col
        sc.poly([at(mid - hw - 0.1, z0 - 4, 0.08), at(mid + hw + 0.1, z0 - 4, 0.08), at(mid + hw + 0.1, z0 - 0.5, 0.08),
                 at(mid - hw - 0.1, z0 - 0.5, 0.08)], sill, face)
        return
    sc.poly([at(mid - hw - 0.08, z0 - 3, 0.07), at(mid + hw + 0.08, z0 - 3, 0.07), at(mid + hw + 0.08, z0 - 1.5, 0.07),
             at(mid - hw - 0.08, z0 - 1.5, 0.07)], sill, face)


DOOR_H = 36.0           # как BuildingArt.DOOR_H в игре


def doors_on_walls(sc: Scene, w: int, h: int, look: Look, doors: list[tuple[int, int]]):
    """Двери на видимых стенах ровно в клетках дверей карты: проём, створка из досок, перемычка, порог.
    Нижний ряд дома — стена +v (вдоль u), правый столбец — стена +u (вдоль v), как is_front в игре."""
    for x, y in doors:
        if y == h - 1:
            door(sc, "u", w, h, x + 0.5, look)
        elif x == w - 1:
            door(sc, "v", w, h, y + 0.5, look)


def door(sc: Scene, axis: str, w: int, h: int, mid: float, look: Look):
    def at(s, z, out):
        return (s, h + out, z) if axis == "u" else (w + out, s, z)
    face = LIGHT["+v" if axis == "u" else "+u"]
    church = look.win == "arch"
    hw = 0.42 if church else 0.32                      # полуширина створки в клетках
    top = DOOR_H + (6 if church else 0)
    stone_wall = look.wall == "stone"
    frame = shade(STONE, 0.62) if stone_wall else shade(look.beam, 0.85)
    arch = (lambda s0, s1, z, out: [at(s0, 0, out), at(s1, 0, out), at(s1, z, out), at(mid, z + 9, out), at(s0, z, out)]) \
        if church else (lambda s0, s1, z, out: [at(s0, 0, out), at(s1, 0, out), at(s1, z, out), at(s0, z, out)])
    sc.poly(arch(mid - hw - 0.08, mid + hw + 0.08, top + 3, 0.03), flat(frame), face)       # наличник / камень
    sc.poly(arch(mid - hw, mid + hw, top, 0.04), flat((30, 20, 12)), face)                    # тёмный проём
    wood = (122, 80, 46) if not church else (98, 60, 36)

    def leaf(u, v, z):
        s = u if axis == "u" else v
        k = (s - (mid - hw * 0.9)) / (hw * 1.8)
        col = shade(wood, 0.92 + 0.14 * noise(np.floor(k * (8 if church else 5)), 0, look.seed + 11))
        seams = np.abs(k * (8 if church else 5) - np.round(k * (8 if church else 5))) < 0.08
        col[seams] = shade(wood, 0.5)
        for zb in (top * 0.22, top * 0.72):                          # поперечины
            col[np.abs(z - zb) < 1.3] = shade(wood, 0.62)
        if church:
            col[np.abs(s - mid) < 0.02] = shade(wood, 0.4)           # две створки
            col[(np.abs(z - top * 0.47) < 1.1) & (np.abs(np.abs(s - mid) - hw * 0.45) < hw * 0.35)] = (52, 46, 44)
        knob = (np.abs(s - (mid + hw * (0.12 if church else 0.6))) < 0.035) & (np.abs(z - top * 0.47) < 1.4)
        col[knob] = (216, 184, 96)
        return col
    sc.poly(arch(mid - hw * 0.9, mid + hw * 0.9, top - 1, 0.05), leaf, face)
    lintel = shade(STONE, 0.75) if stone_wall else shade(look.beam, 1.05)
    if not church:
        sc.poly([at(mid - hw - 0.12, top + 3, 0.06), at(mid + hw + 0.12, top + 3, 0.06),
                 at(mid + hw + 0.12, top + 6, 0.06), at(mid - hw - 0.12, top + 6, 0.06)], flat(lintel), face)
    # порог: каменная ступенька перед дверью
    s0, s1 = mid - hw - 0.1, mid + hw + 0.1
    step = lambda u, v, z: stone(u + v, z, look.seed + 13, (126, 120, 110))
    if axis == "u":
        box(sc, (s0, h, 0), (s1, h + 0.22, 3), step, top_col=(150, 144, 132))
    else:
        box(sc, (w, s0, 0), (w + 0.22, s1, 3), step, top_col=(150, 144, 132))


def k_flowers(mid: float, z0: float, look: Look) -> bool:
    return noise(int(mid * 2), int(z0), look.seed + 8) > 0.35


def arch_window(sc: Scene, axis: str, w: int, h: int, mid: float, look: Look):
    """Узкое стрельчатое окно церкви с цветным стеклом."""
    def at(s, z, out=0.03):
        return (s, h + out, z) if axis == "u" else (w + out, s, z)
    face = LIGHT["+v" if axis == "u" else "+u"]
    hw, z0, z1 = 0.13, 16.0, look.wall_h - 14
    stone_frame = shade(STONE, 0.6)
    sc.poly([at(mid - hw - 0.06, z0 - 2), at(mid + hw + 0.06, z0 - 2), at(mid + hw + 0.06, z1),
             at(mid, z1 + 7), at(mid - hw - 0.06, z1)], flat(stone_frame), face)

    def glass(u, v, z):
        s = u if axis == "u" else v
        pane = noise(np.floor((s - mid) * 40), np.floor(z / 4), look.seed + 3)
        tones = np.asarray([(70, 92, 140), (150, 60, 52), (196, 160, 76), (60, 110, 96)], float)
        col = tones[(pane * 4).astype(int) % 4] * 0.85
        lead = (np.abs((s - mid) * 40 - np.round((s - mid) * 40)) < 0.12) | (np.abs(z / 4 - np.round(z / 4)) < 0.12)
        col[lead] = (30, 26, 28)
        return col
    sc.poly([at(mid - hw, z0, 0.05), at(mid + hw, z0, 0.05), at(mid + hw, z1, 0.05), at(mid, z1 + 5, 0.05),
             at(mid - hw, z1, 0.05)], glass, 1.0)


# --- Особые постройки ----------------------------------------------------------------------------------------

def spire_tower(sc: Scene, u0, v0, size, z0, height, roof_col, seed, belfry=True, cross=True):
    """Каменная башня с шатром и крестом (колокольня церкви и отдельная колокольня — одна и та же)."""
    u1, v1 = u0 + size, v0 + size
    zt = z0 + height
    st = lambda u, v, z: stone(u + v, z, seed, STONE)
    sc.poly([(u0, v1, z0), (u1, v1, z0), (u1, v1, zt), (u0, v1, zt)], st, LIGHT["+v"])
    sc.poly([(u1, v0, z0), (u1, v1, z0), (u1, v1, zt), (u1, v0, zt)], st, LIGHT["+u"])
    if belfry:
        for axis in ("u", "v"):
            for k in range(max(1, int(size))):
                mid = (u0 if axis == "u" else v0) + (k + 0.5) * size / max(1, int(size))
                hw = 0.18 * size / max(1, int(size))
                zb = zt - 22

                def arch(u, v, z, mid=mid, axis=axis, zb=zb, hw=hw):
                    s = u if axis == "u" else v
                    col = full(len(u), (26, 22, 24))
                    bell = (np.abs(s - mid) < hw * 0.55) & (z < zb + 9) & (z > zb + 2)
                    col[bell] = (168, 128, 60)
                    return col
                pts = [(mid - hw, v1 + 0.02, zb), (mid + hw, v1 + 0.02, zb), (mid + hw, v1 + 0.02, zb + 13),
                       (mid, v1 + 0.02, zb + 17), (mid - hw, v1 + 0.02, zb + 13)] if axis == "u" else \
                      [(u1 + 0.02, mid - hw, zb), (u1 + 0.02, mid + hw, zb), (u1 + 0.02, mid + hw, zb + 13),
                       (u1 + 0.02, mid, zb + 17), (u1 + 0.02, mid - hw, zb + 13)]
                sc.poly(pts, arch, LIGHT["+v" if axis == "u" else "+u"])
    cu, cv = (u0 + u1) / 2, (v0 + v1) / 2
    peak = zt + size * 30
    e = 0.15
    look = Look(roof="slate", roof_col=roof_col, seed=seed)
    roof = roof_shader(look, peak, "u")
    sc.poly([(u0 - e, v1 + e, zt - 2), (u1 + e, v1 + e, zt - 2), (cu, cv, peak)], roof, LIGHT["+v"])
    sc.poly([(u1 + e, v0 - e, zt - 2), (u1 + e, v1 + e, zt - 2), (cu, cv, peak)], roof, LIGHT["+u"])
    if cross:
        gold = (214, 182, 96)
        sc.poly([(cu - 0.03, cv + 0.03, peak), (cu + 0.03, cv + 0.03, peak), (cu + 0.03, cv + 0.03, peak + 14),
                 (cu - 0.03, cv + 0.03, peak + 14)], flat(gold))
        sc.poly([(cu - 0.2, cv + 0.04, peak + 8), (cu + 0.2, cv + 0.04, peak + 8), (cu + 0.2, cv + 0.04, peak + 10),
                 (cu - 0.2, cv + 0.04, peak + 10)], flat(gold))
    return peak + 14


def church_details(sc: Scene, w: int, h: int, look: Look, doors: list[tuple[int, int]], geo: dict):
    """Контрфорсы вдоль длинной стены, круглое окно-роза на фронтоне, башенка с шатром и крестом на коньке."""
    H, ridge_z, along_u = look.wall_h, geo["ridge_z"], geo["along_u"]
    L = w if along_u else h                                  # длинная видимая стена
    door_cells = {x for x, y in doors if y == h - 1} if along_u else {y for x, y in doors if x == w - 1}
    st = lambda u, v, z: stone(u + v, z, look.seed + 5, shade(STONE, 0.92))
    for i in range(1, L):
        if i % 2 or door_cells & {i - 1, i}:
            continue
        if along_u:
            box(sc, (i - 0.16, h, 0), (i + 0.16, h + 0.32, H - 14), st, top_col=shade(STONE, 0.8))
        else:
            box(sc, (w, i - 0.16, 0), (w + 0.32, i + 0.16, H - 14), st, top_col=shade(STONE, 0.8))
    # окно-роза на ближнем фронтоне
    B = h if along_u else w
    rise = ridge_z - H
    zc, rs, rz = H + rise * 0.36, min(0.75, B * 0.1), min(13.0, rise * 0.3)

    def at(t, z, out):
        return (w + out, h / 2 + t, z) if along_u else (w / 2 + t, h + out, z)
    ring = [at(rs * 1.25 * math.cos(a), zc + rz * 1.25 * math.sin(a), 0.03) for a in np.linspace(0, 2 * math.pi, 20)[:-1]]
    face = LIGHT["+u" if along_u else "+v"]
    sc.poly(ring, flat(shade(STONE, 0.62)), face)

    def rose(u, v, z):
        t = (v - h / 2) if along_u else (u - w / 2)
        ang = np.arctan2((z - zc) / rz, t / rs)
        rad = np.hypot((z - zc) / rz, t / rs)
        sector = np.floor((ang + math.pi) / (2 * math.pi) * 8).astype(int) % 8
        tones = np.asarray([(70, 92, 150), (160, 58, 50), (204, 168, 80), (64, 116, 100)], float)
        col = tones[sector % 4] * (0.75 + 0.3 * np.clip(1 - rad, 0, 1))[:, None]
        col[rad < 0.32] = (214, 180, 90)
        lead = (np.abs(rad - 0.32) < 0.08) | (np.abs(((ang + math.pi) / (2 * math.pi) * 8) % 1 - 0.5) > 0.42)
        col[lead & (rad > 0.32)] = (34, 28, 30)
        return col
    sc.poly([at(rs * math.cos(a), zc + rz * math.sin(a), 0.05) for a in np.linspace(0, 2 * math.pi, 20)[:-1]], rose, 1.0)
    # башенка на коньке у ближнего торца
    size = 0.9
    if along_u:
        u0, v0 = w - 1.7 - size / 2, h / 2 - size / 2
    else:
        u0, v0 = w / 2 - size / 2, h - 1.7 - size / 2
    spire_tower(sc, u0, v0, size, ridge_z - 12, 36, ROOF["slate"][1], look.seed + 1)


def hanging_sign(img: Image.Image, sc: Scene, w: int, h: int, z: float):
    """Вывеска таверны на кронштейне у ближнего угла: тёмная доска с вороном."""
    d = ImageDraw.Draw(img)
    x, y = sc.screen((w, h, z))
    x, y = int(round(x)), int(round(y))
    d.line([(x, y), (x - 16, y + 8)], fill=(40, 28, 20), width=2)
    bx, by = x - 18, y + 9
    d.line([(bx - 1, by), (bx - 1, by + 3)], fill=(30, 22, 16))
    d.line([(bx - 11, by + 3), (bx - 11, by - 2)], fill=(30, 22, 16))
    d.rectangle([bx - 15, by + 3, bx + 3, by + 16], fill=(96, 64, 38), outline=OUTLINE)
    d.rectangle([bx - 13, by + 5, bx + 1, by + 14], outline=(150, 112, 60))
    raven = ((-8, 8), (-7, 8), (-6, 9), (-7, 9), (-8, 9), (-9, 10), (-5, 9), (-4, 10), (-7, 10), (-6, 10), (-8, 11),
             (-10, 11), (-3, 10), (-6, 11))
    for px, py in raven:
        d.point((bx + px, by + py), fill=(18, 14, 16))


def antlers(img: Image.Image, sc: Scene, apex):
    """Оленьи рога над фронтоном (хижина Ветлы)."""
    d = ImageDraw.Draw(img)
    x, y = (int(round(c)) for c in sc.screen(apex))
    bone = (206, 194, 168)
    for side in (-1, 1):
        d.line([(x, y - 1), (x + side * 4, y - 6), (x + side * 7, y - 12)], fill=bone, width=1)
        d.line([(x + side * 4, y - 6), (x + side * 8, y - 7)], fill=bone)
        d.line([(x + side * 6, y - 10), (x + side * 9, y - 13)], fill=bone)
    d.rectangle([x - 1, y - 2, x + 1, y], fill=(170, 156, 130))


def skull(img: Image.Image, sc: Scene, apex):
    """Череп на шесте у шалаша шамана."""
    d = ImageDraw.Draw(img)
    x, y = (int(round(c)) for c in sc.screen(apex))
    bone = (222, 214, 190)
    d.line([(x, y), (x, y - 14)], fill=(70, 50, 34), width=2)
    for side in (-1, 1):                                     # рога
        d.line([(x + side * 3, y - 19), (x + side * 7, y - 22), (x + side * 8, y - 27)], fill=(196, 182, 150), width=2)
    d.rectangle([x - 4, y - 21, x + 4, y - 14], fill=bone, outline=OUTLINE)
    d.rectangle([x - 2, y - 14, x + 2, y - 12], fill=bone, outline=OUTLINE)
    d.rectangle([x - 3, y - 19, x - 2, y - 17], fill=(30, 24, 22))
    d.rectangle([x + 2, y - 19, x + 3, y - 17], fill=(30, 24, 22))
    for k in (-1, 0, 1):                                     # перья
        d.line([(x + k, y - 8), (x + k * 3, y - 2)], fill=(150, 40, 32) if k else (40, 34, 30))


def herbs(img: Image.Image, sc: Scene, w: int, h: int, z: float, seed: int):
    """Пучки трав под свесом крыши (хижина Ветлы)."""
    d = ImageDraw.Draw(img)
    cols = [(92, 120, 58), (132, 112, 60), (110, 70, 80), (80, 100, 50)]
    spots = [(i + 0.5, h + 0.25) for i in range(w)] + [(w + 0.25, j + 0.5) for j in range(h)]
    for k, (u, v) in enumerate(spots):
        if noise(k, 1, seed) < 0.3:
            continue
        x, y = sc.screen((u, v, z))
        x, y = int(round(x)), int(round(y))
        c = cols[int(noise(k, 2, seed) * len(cols)) % len(cols)]
        dark = tuple(int(q) for q in shade(c, 0.55))
        d.line([(x, y), (x, y + 3)], fill=(60, 44, 30))
        d.polygon([(x - 1, y + 3), (x + 1, y + 3), (x + 4, y + 13), (x - 4, y + 13)], fill=c, outline=dark)
        d.line([(x - 2, y + 5), (x + 2, y + 5)], fill=(150, 120, 70))       # перевязь
        d.point((x - 2, y + 14), fill=c)
        d.point((x + 1, y + 14), fill=c)


# --- Что за дом ------------------------------------------------------------------------------------------------

def look_for(b: dict) -> tuple[Look, str]:
    """Вид дома по полям карты: material, roof, chimney, cross, sprite-подсказка (house_b / house_c / house_log)."""
    bid = str(b.get("id", "house"))
    seed = seed_of(bid + str(b.get("rect")))
    pick = lambda arr, k=0: arr[int(noise(k, 11, seed) * len(arr)) % len(arr)]
    material = str(b.get("material", "timber"))
    roof = str(b.get("roof", "shingle"))
    hints = b.get("sprite", "")
    hints = [hints] if isinstance(hints, str) else list(hints)
    look = Look(wall=material, roof=roof, seed=seed, chimney=bool(b.get("chimney", False)) or noise(1, 1, seed) > 0.55,
                plaster=pick(PLASTER, 1), beam=pick(BEAMS, 2), shutter=pick(SHUTTERS, 3),
                roof_col=pick(ROOF.get(roof, ROOF["shingle"]), 4))
    special = ""
    look.flowers = material in ("timber", "plaster") and noise(2, 2, seed) > 0.55
    look.cross_ridge = noise(3, 3, seed) > 0.62
    w, h = (int(v) for v in b.get("rect", [0, 0, 6, 5])[2:])
    style = noise(5, 5, seed)
    if "house_b" in hints or (material == "timber" and not hints[0].startswith("house_c") and 0.42 < style < 0.72):
        look.wall, look.braces, look.plaster = "plaster", False, (214, 206, 186)
    elif "house_c" in hints or (material == "timber" and style >= 0.72 and w * h >= 30):
        look.floors, look.wall_h, look.pitch = 2, 68.0, 17.0       # двухэтажный
    elif "house_log" in hints:
        look.wall = "log"
    if bid == "church":
        special = "church"
        look.wall_h, look.pitch, look.lit, look.chimney = 58.0, 18.0, 0.0, False
        look.roof_col, look.win, look.flowers, look.cross_ridge = ROOF["slate"][0], "arch", False, False
    elif bid == "tavern":
        special = "tavern"
        look.floors, look.wall_h, look.lit, look.chimney, look.cross_ridge = 2, 74.0, 0.85, True, False
        look.plaster, look.roof_col = (204, 186, 146), ROOF["shingle"][0]
    elif bid == "smithy":
        special = "smithy"
        look.lit, look.chimney, look.cross_ridge = 0.0, True, False
    elif bid == "vetla_hut":
        special = "hut"
        look.pitch, look.lit, look.flowers, look.cross_ridge = 20.0, 0.5, False, False
        look.wall_h, look.wall = 44.0, "log"
    elif bid == "crypt":
        special = "crypt"
        look.wall_h, look.lit, look.chimney, look.pitch, look.win = 40.0, 0.0, False, 16.0, "none"
    elif bid == "house_headman":       # староста: два этажа, цветы, труба
        special = "headman"
        look.wall, look.braces, look.floors, look.wall_h, look.pitch = "timber", True, 2, 72.0, 16.0
        look.flowers, look.chimney, look.lit, look.cross_ridge = True, True, 0.8, False
        look.plaster, look.roof_col = (206, 192, 156), ROOF["shingle"][0]
    elif bid.startswith("barn") or bid == "shed":
        special = "barn"
        look.wall_h, look.pitch, look.lit, look.chimney, look.flowers = 44.0, 20.0, 0.0, False, False
    elif bid == "shaman_hut":
        special = "shaman"
        look.wall, look.roof, look.roof_col = "sticks", "hide", ROOF["hide"][0]
        look.wall_h, look.pitch, look.lit, look.chimney, look.win = 34.0, 22.0, 0.0, False, "none"
    return look, special


def render_building(b: dict) -> Image.Image:
    r = b["rect"]
    w, h = int(r[2]), int(r[3])
    doors = [(int(d[0]) - int(r[0]), int(d[1]) - int(r[1])) for d in b.get("doors", [])]
    look, special = look_for(b)
    extra = 0.0
    if special == "church":
        extra = 50.0
    sc = house_scene(w, h, look, extra)
    geo = build_house(sc, w, h, look, doors)
    if special == "church":            # большая колокольня стоит рядом (props/bell_tower), на храме — башенка на коньке
        church_details(sc, w, h, look, doors, geo)
    if special == "smithy":
        H = look.wall_h
        box(sc, (w - 1.6, h - 1.6, H - 4), (w - 0.8, h - 0.8, H + min(w, h) / 2 * look.pitch + 22),
            lambda u, v, z: stone(u + v, z, look.seed + 4, (96, 90, 84)), top_col=(232, 120, 40))
    img = sc.image(56 if special == "church" else 40)
    if special == "tavern":
        hanging_sign(img, sc, w, h, look.wall_h * 0.62)
    if special == "hut":
        herbs(img, sc, w, h, look.wall_h - 2, look.seed)
        antlers(img, sc, geo["apex"])
    if special == "shaman":
        skull(img, sc, geo["apex"])
    return tighten(img)


def walled(rows: list[str], x: int, y: int, w: int, h: int, ch: str) -> bool:
    """Место дома обнесено стенами (=, + и сама буква в углу) — иначе буква стоит не на доме."""
    edge = [(xx, yy) for yy in range(y, y + h) for xx in range(x, x + w)
            if yy in (y, y + h - 1) or xx in (x, x + w - 1)]
    good = sum(1 for xx, yy in edge if yy < len(rows) and xx < len(rows[yy]) and rows[yy][xx] in ("=", "+", ch))
    return good >= 0.8 * len(edge)


def scene_from_cells(maps: dict, warn: bool = True) -> list[dict]:
    """Дома из карт: те же поля, что даёт LocationData (rect, doors, material, roof ...)."""
    out = []
    for lid, loc in maps.items():
        if not isinstance(loc, dict) or "rows" not in loc:
            continue
        rows, legend = loc["rows"], loc.get("legend", {})
        for y, row in enumerate(rows):
            for x, ch in enumerate(row):
                e = legend.get(ch, {})
                if "building" not in e:
                    continue
                w, h = e.get("size", [3, 3])
                if not walled(rows, x, y, w, h, ch):
                    if warn:
                        print("  ! %s: буква «%s» в (%d, %d) не в углу стен — это не дом (та же буква у мебели?)"
                              % (lid, ch, x, y))
                    continue
                doors = [[xx, yy] for yy in range(y, y + h) for xx in range(x, x + w)
                         if yy < len(rows) and xx < len(rows[yy]) and rows[yy][xx] == "+"]
                b = {k: v for k, v in e.items() if k not in ("building", "size")}
                b.update(id=str(e["building"]), rect=[x, y, w, h], doors=doors, location=lid)
                out.append(b)
    return out


# --- Колокольня, колодец, доска объявлений -------------------------------------------------------------------

def render_bell_tower() -> Image.Image:
    """Отдельная колокольня на место 2×2: та же башня, что у церкви, тот же камень и шатёр."""
    sc = footprint_scene(2, 2, TOWER_H + 90)
    spire_tower(sc, 0, 0, 2, 0, TOWER_H, ROOF["slate"][1], seed_of("bell_tower"))
    return tighten(sc.image())


def render_well() -> Image.Image:
    """Колодец на клетку 2×2: каменное кольцо, два столба, крыша-домик, ворот и ведро."""
    sc = footprint_scene(2, 2, 80)
    seed = seed_of("well")
    ring = lambda u, v, z: stone(u * 1.7 + v * 1.7, z, seed, (128, 122, 112))
    n = 12
    c, rad, hz = 1.0, 0.8, 14.0
    for i in range(n):                                 # кольцо из граней
        a0, a1 = 2 * math.pi * i / n, 2 * math.pi * (i + 1) / n
        p0 = (c + rad * math.cos(a0), c + rad * math.sin(a0))
        p1 = (c + rad * math.cos(a1), c + rad * math.sin(a1))
        nx, ny = math.cos((a0 + a1) / 2), math.sin((a0 + a1) / 2)
        lightk = 0.7 + 0.3 * max(0.0, nx * 0.8 + ny * 0.5)
        sc.poly([(p0[0], p0[1], 0), (p1[0], p1[1], 0), (p1[0], p1[1], hz), (p0[0], p0[1], hz)], ring, lightk)
    top = [(c + rad * math.cos(2 * math.pi * i / n), c + rad * math.sin(2 * math.pi * i / n), hz) for i in range(n)]
    sc.poly(top, lambda u, v, z: full(len(u), (150, 142, 128)), 1.0)
    inner = [(c + rad * 0.72 * math.cos(2 * math.pi * i / n), c + rad * 0.72 * math.sin(2 * math.pi * i / n), hz + 0.3)
             for i in range(n)]
    sc.poly(inner, lambda u, v, z: full(len(u), (22, 26, 34)), 1.0)
    wood = lambda u, v, z: shade((98, 70, 44), 0.9 + 0.2 * noise(np.floor(z / 3), 0, seed))
    for pu, pv in ((c - 0.06, c - rad - 0.05), (c - 0.06, c + rad - 0.07)):
        box(sc, (pu, pv, 0), (pu + 0.14, pv + 0.14, 46), wood)
    sc.poly([(c - 0.02, c - rad, 30), (c + 0.04, c - rad, 30), (c + 0.04, c + rad, 30), (c - 0.02, c + rad, 30)],
            flat((70, 50, 32)))
    look = Look(roof="shingle", roof_col=ROOF["shingle"][0], seed=seed)
    ridge = 58.0
    roof = roof_shader(look, ridge, "v")
    sc.poly([(c - 0.75, c - rad - 0.3, 42), (c, c - rad - 0.3, ridge), (c, c + rad + 0.3, ridge), (c - 0.75, c + rad + 0.3, 42)], roof, 0.72)
    sc.poly([(c, c - rad - 0.3, ridge), (c + 0.75, c - rad - 0.3, 42), (c + 0.75, c + rad + 0.3, 42), (c, c + rad + 0.3, ridge)], roof, 1.05)
    sc.poly([(c - 0.75, c + rad + 0.3, 42), (c, c + rad + 0.3, ridge), (c + 0.75, c + rad + 0.3, 42)],
            boards_shader((96, 70, 46), seed), LIGHT["+v"])
    box(sc, (c + 0.1, c + 0.05, 22), (c + 0.32, c + 0.27, 29), lambda u, v, z: shade((110, 78, 48), 1.0), top_col=(40, 46, 56))
    return tighten(sc.image())


def cell_scene(top: float, half_w: int) -> Scene:
    """Холст для предмета на одной клетке: середина клетки — середина нижнего края (так игра ставит предметы 1×1)."""
    cw = 2 * half_w
    ch = int(math.ceil(top)) + 4
    return Scene(cw, ch, ch - 9, cw / 2)


def render_notice_board() -> Image.Image:
    """Доска объявлений на клетку, лицом к зрителю: два столба, козырёк, листы на красных кнопках."""
    sc = cell_scene(92, 40)
    seed = seed_of("notice_board")
    s0, A = 0.9, 0.8                       # доска на линии u + v = s0, полудлина A клетки (около 50 px на экране)

    def at(a, z, d=0.0):                   # a — вдоль доски, d — к зрителю
        return (s0 / 2 + a + d, s0 / 2 - a + d, z)
    wood = lambda u, v, z: shade((96, 68, 42), 0.88 + 0.22 * noise(np.floor(z / 3), np.floor((u - v) * 4), seed))
    for a in (-A + 0.06, A - 0.06):
        cu, cv = s0 / 2 + a, s0 / 2 - a
        box(sc, (cu - 0.05, cv - 0.05, 0), (cu + 0.05, cv + 0.05, 66), wood)

    def board(u, v, z):
        col = shade((122, 88, 54), 0.84 + 0.16 * noise(np.floor(z / 5), np.floor((u - v) * 6), seed))
        col[np.abs(z / 5 - np.round(z / 5)) < 0.12] = (66, 46, 28)
        return col
    lit = (LIGHT["+u"] + LIGHT["+v"]) / 2
    sc.poly([at(-A - 0.05, 15, 0.06), at(A + 0.05, 15, 0.06), at(A + 0.05, 53, 0.06), at(-A - 0.05, 53, 0.06)],
            flat((70, 48, 30)), lit)
    sc.poly([at(-A + 0.02, 18, 0.07), at(A - 0.02, 18, 0.07), at(A - 0.02, 50, 0.07), at(-A + 0.02, 50, 0.07)],
            board, lit)
    look = Look(roof="shingle", roof_col=ROOF["shingle"][1], seed=seed)
    roof = roof_shader(look, 72, "u")
    e = A + 0.14
    sc.poly([at(-e, 72, 0), at(e, 72, 0), at(e, 60, 0.3), at(-e, 60, 0.3)], roof, 1.0)
    sc.poly([at(-e, 60, -0.3), at(e, 60, -0.3), at(e, 72, 0), at(-e, 72, 0)], roof, 0.72)
    img = sc.image()
    # листы прямо в картинке: доска смотрит на зрителя, так что это прямоугольники на экране
    d = ImageDraw.Draw(img)
    x0, y0 = (int(round(c)) for c in sc.screen(at(-A + 0.02, 50, 0.07)))
    x1, y1 = (int(round(c)) for c in sc.screen(at(A - 0.02, 18, 0.07)))
    papers = [(0.04, 0.10, 0.30, 0.62, 0), (0.37, 0.06, 0.62, 0.48, 1), (0.66, 0.14, 0.95, 0.70, 0),
              (0.36, 0.56, 0.60, 0.94, 1), (0.08, 0.68, 0.30, 0.96, 1)]
    for k, (fx0, fy0, fx1, fy1, tone) in enumerate(papers):
        px0, py0 = x0 + int(fx0 * (x1 - x0)), y0 + int(fy0 * (y1 - y0))
        px1, py1 = x0 + int(fx1 * (x1 - x0)), y0 + int(fy1 * (y1 - y0))
        paper = (234, 224, 194) if tone == 0 else (214, 198, 160)
        d.rectangle([px0 + 1, py0 + 1, px1 + 1, py1 + 1], fill=(48, 34, 22))
        d.rectangle([px0, py0, px1, py1], fill=paper, outline=(120, 100, 74))
        if k == 1:                                         # «разыскивается»: лицо углём
            cx = (px0 + px1) // 2
            d.ellipse([cx - 3, py0 + 3, cx + 3, py0 + 9], outline=(60, 50, 44))
            d.line([(px0 + 2, py1 - 3), (px1 - 2, py1 - 3)], fill=(150, 40, 32))
        else:
            for ly in range(py0 + 4, py1 - 1, 3):
                d.line([(px0 + 2, ly), (px1 - 2 - (ly * 7 + k) % 4, ly)], fill=(128, 110, 88))
        pin = ((px0 + px1) // 2, py0)
        d.rectangle([pin[0] - 1, pin[1] - 1, pin[0] + 1, pin[1] + 1], fill=(176, 40, 32), outline=OUTLINE)
    return tighten(img)


def render_notice_board_ui(pages: int = 4) -> tuple[Image.Image, dict]:
    """Большая доска для окна объявлений: доски, рама с железными уголками, табличка для заголовка и чистые листы.
    Возвращает картинку и места для текста игры: {"title": [x, y, w, h], "pages": [[x, y, w, h], ...]}."""
    W, H, top = 400, 280, 22                      # сверху над рамой — табличка заголовка
    ys, xs = np.mgrid[0:H, 0:W]
    plank = xs // 40                              # доски стоят стоймя
    grain = 0.1 * noise(plank, ys // 5, 5) + 0.06 * noise(xs // 2, ys // 7 + plank * 31, 9) \
        + 0.05 * np.sin((ys + 13 * plank) / 9.0 + 3 * noise(plank, 0, 2))
    a = np.asarray((106, 74, 46), float) * (0.8 + grain + 0.06 * (plank % 2))[..., None]
    a[(xs % 40) < 2] = (46, 30, 20)
    for k in range(W // 40):                      # сучки
        kx, ky = k * 40 + 8 + int(noise(k, 1, 4) * 24), top + 30 + int(noise(k, 2, 4) * (H - top - 60))
        a[((xs - kx) ** 2 / 9 + (ys - ky) ** 2 / 4) < 1.5] = (64, 42, 26)
    fr = 14
    frame = ((xs < fr) | (xs >= W - fr) | (ys < top + fr) | (ys >= H - fr)) & (ys >= top)
    bevel = np.where((xs < fr) | (ys < top + fr), 1.12, 0.78)
    a[frame] = (np.asarray((82, 56, 34), float) * (bevel * (0.92 + 0.16 * noise(xs // 6, ys // 3, 3)))[..., None])[frame]
    a[ys < top] = 0
    alpha = np.where(ys >= top, 255, 0).astype(np.uint8)
    img = Image.fromarray(np.dstack([np.clip(a, 0, 255).astype(np.uint8), alpha]), "RGBA")
    d = ImageDraw.Draw(img)
    d.rectangle([0, top, W - 1, H - 1], outline=OUTLINE)
    d.rectangle([fr - 1, top + fr - 1, W - fr, H - fr], outline=(40, 26, 16))
    iron, iron_hi = (62, 60, 58), (120, 116, 108)
    for cx, cy, sx, sy in ((0, top, 1, 1), (W - 1, top, -1, 1), (0, H - 1, 1, -1), (W - 1, H - 1, -1, -1)):
        pts = [(cx, cy), (cx + sx * 24, cy), (cx + sx * 24, cy + sy * 6), (cx + sx * 6, cy + sy * 6),
               (cx + sx * 6, cy + sy * 24), (cx, cy + sy * 24)]
        d.polygon(pts, fill=iron, outline=OUTLINE)
        for nx, ny in ((cx + sx * 3, cy + sy * 3), (cx + sx * 18, cy + sy * 3), (cx + sx * 3, cy + sy * 18)):
            d.rectangle([nx - 1, ny - 1, nx, ny], fill=iron_hi)
    # табличка заголовка поверх рамы
    tw, th = 176, 30
    tx, ty = (W - tw) // 2, 2
    for k in (-1, 1):                                                   # верёвочки
        d.line([(W // 2 + k * 60, ty + 4), (W // 2 + k * 70, top + 2)], fill=(150, 120, 80), width=2)
    d.rectangle([tx + 2, ty + 3, tx + tw + 2, ty + th + 3], fill=(30, 20, 12))
    d.rectangle([tx, ty, tx + tw, ty + th], fill=(132, 94, 58), outline=OUTLINE)
    d.rectangle([tx + 3, ty + 3, tx + tw - 3, ty + th - 3], outline=(92, 62, 36))
    d.line([(tx + 4, ty + 2), (tx + tw - 4, ty + 2)], fill=(166, 124, 80))
    title = [tx + 8, ty + 5, tw - 16, th - 10]
    # листы
    rng = np.random.default_rng(7)
    rects, pins = [], []
    cols = 2 if pages <= 4 else 3
    rows = math.ceil(pages / cols)
    x_in, y_in = fr + 8, top + fr + 6
    cw, chh = (W - 2 * x_in) // cols, (H - y_in - fr - 4) // rows
    for i in range(pages):
        cx, cy = x_in + (i % cols) * cw, y_in + (i // cols) * chh
        pw, ph = cw - 14 - int(rng.integers(0, 10)), chh - 12 - int(rng.integers(0, 8))
        x0 = cx + (cw - pw) // 2 + int(rng.integers(-3, 4))
        y0 = cy + 5 + int(rng.integers(-2, 3))
        paper = np.asarray((236, 226, 196) if i % 2 == 0 else (226, 212, 176), float)
        d.rectangle([x0 + 3, y0 + 4, x0 + pw + 3, y0 + ph + 4], fill=(36, 24, 14))       # тень
        py, px = np.mgrid[0:ph + 1, 0:pw + 1]
        edge = np.minimum(np.minimum(px, pw - px), np.minimum(py, ph - py))
        age = 0.8 + 0.2 * np.clip(edge / 10, 0, 1) - 0.04 * noise(px // 3, py // 3, 11 + i)
        tile = np.clip(paper * age[..., None], 0, 255).astype(np.uint8)
        img.paste(Image.fromarray(tile, "RGB"), (x0, y0))
        d.line([(x0, y0), (x0 + pw, y0)], fill=tuple(int(c * 0.7) for c in paper))
        d.line([(x0, y0), (x0, y0 + ph - 3)], fill=tuple(int(c * 0.75) for c in paper))
        d.line([(x0 + pw, y0), (x0 + pw, y0 + ph - 3)], fill=tuple(int(c * 0.6) for c in paper))
        d.polygon([(x0 + pw, y0 + ph), (x0 + pw - 9, y0 + ph), (x0 + pw, y0 + ph - 9)], fill=(98, 68, 42))   # загиб
        d.line([(x0 + pw - 9, y0 + ph), (x0 + pw, y0 + ph - 9)], fill=tuple(int(c * 0.8) for c in paper))
        pins.append((i, (x0 + pw // 2, y0 + 3), (x0 + pw - 18, y0 + ph - 20)))
        rects.append([x0 + 8, y0 + 10, pw - 16, ph - 20])
    q = np.asarray(img.convert("RGB").quantize(96, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
                   .convert("RGB"))                                # пиксель-арт: импорт не станет его пережимать
    img = Image.fromarray(np.dstack([q, np.asarray(img)[..., 3]]), "RGBA")
    d = ImageDraw.Draw(img)                                         # кнопки и печать — после, чтобы не потускнели
    for i, pin, seal in pins:
        if i % 3 == 2:                                                     # гвоздь
            d.rectangle([pin[0] - 2, pin[1] - 2, pin[0] + 2, pin[1] + 2], fill=iron, outline=OUTLINE)
            d.point(pin, fill=iron_hi)
        else:                                                              # красная кнопка
            d.ellipse([pin[0] - 3, pin[1] - 3, pin[0] + 3, pin[1] + 3], fill=(176, 40, 32), outline=OUTLINE)
            d.point((pin[0] - 1, pin[1] - 1), fill=(232, 120, 100))
        if i == 1:                                                         # сургучная печать
            sx, sy = seal
            d.ellipse([sx - 6, sy - 6, sx + 6, sy + 6], fill=(140, 30, 30), outline=(70, 14, 14))
            d.ellipse([sx - 3, sy - 3, sx + 3, sy + 3], outline=(190, 70, 60))
    return img, {"title": title, "pages": rects}


def sprite_id(building: str) -> str:
    """Имя картинки: импорт пишет имена строчными, а дома house_L и house_l разные — заглавная буква удваивается."""
    return "bld_" + "".join(c.lower() * 2 if c.isupper() else c for c in building)


def save(img: Image.Image, out: Path, sid: str, bind: str, crop: bool = False):
    out.mkdir(parents=True, exist_ok=True)
    img.save(out / (sid + ".png"))
    hint = {"id": sid, "bind": bind, "kind": "image", "cols": 1, "rows_count": 1}
    if not crop:
        hint["crop"] = False
    if sid.startswith("bld_"):
        hint["doors"] = True            # двери нарисованы: игра свою дверь поверх не рисует
    (out / (sid + ".art.json")).write_text(json.dumps(hint, ensure_ascii=False) + "\n", encoding="utf-8")


def preview(maps: dict, sprites: dict[str, Image.Image], loc: str, path: Path, scale: int = 1,
            extras: dict[str, Image.Image] | None = None):
    """Карта сверху: земля ромбами, дома и колокольня, колодец, доска на своих местах (для проверки без игры)."""
    m = maps[loc]
    rows = m["rows"]
    W, H = len(rows[0]), len(rows)
    ox = H * 16 + 40
    cw, ch = (W + H) * 16 + 80, (W + H) * 8 + 260
    img = Image.new("RGBA", (cw, ch), (24, 20, 18, 255))
    d = ImageDraw.Draw(img)
    oy = 220
    for y in range(H):
        for x in range(W):
            X, Y = ox + 16 * (x - y), oy + 8 * (x + y)
            col = (92, 70, 46) if (x + y) % 2 else (98, 74, 48)
            if rows[y][x] == "#":
                col = (40, 36, 30)
            d.polygon([(X, Y), (X + 16, Y + 8), (X, Y + 16), (X - 16, Y + 8)], fill=col)
    items = []
    for b in scene_from_cells({loc: m}, warn=False):
        x, y, w, h = b["rect"]
        sp = sprites.get(b["id"])
        if sp is None:
            continue
        X, Y = ox + 16 * ((x + w) - (y + h)) - 8 * (w - h), oy + 8 * ((x + w) + (y + h))   # середина ромба
        items.append((Y, X, sp))
    legend = m.get("legend", {})
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            e = legend.get(ch, {})
            what = str(e.get("object", e.get("prop", "")))
            if not extras or what not in extras:
                continue
            w, h = e.get("size", [2, 2] if what == "well" else [1, 1])     # колодец на 2×2 — см. render_well
            if w > 1 or h > 1:
                X, Y = ox + 16 * ((x + w) - (y + h)), oy + 8 * ((x + w) + (y + h))
            else:
                X, Y = ox + 16 * (x - y), oy + 8 * (x + y + 1)
            items.append((Y, X, extras[what]))
    for Y, X, sp in sorted(items, key=lambda t: t[0]):
        img.alpha_composite(sp, (int(X - sp.width / 2), int(Y - sp.height + 1)))
    if scale != 1:
        img = img.resize((img.width * scale, img.height * scale), Image.NEAREST)
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--maps", default=str(ROOT / "data" / "locations.json"))
    ap.add_argument("--out", default=str(ROOT / "art" / "inbox" / "buildings"))
    ap.add_argument("--preview", default="", help="картинка деревни для проверки (art/review/village.png)")
    ap.add_argument("--location", default="village")
    args = ap.parse_args(argv)
    maps = json.loads(Path(args.maps).read_text(encoding="utf-8"))
    out = Path(args.out)
    for f in list(out.glob("bld_*.png")) + list(out.glob("bld_*.art.json")):    # дома, которых больше нет на карте
        f.unlink()
    sprites = {}
    for b in scene_from_cells(maps):
        if b["id"] in sprites:
            continue
        sprites[b["id"]] = render_building(b)
        save(sprites[b["id"]], out, sprite_id(b["id"]), "props/bld_" + b["id"])
        print("  props/bld_%s: %s %d×%d" % (b["id"], b.get("location"), b["rect"][2], b["rect"][3]))
    extras = {"bell_tower": render_bell_tower(), "well": render_well(), "notice_board": render_notice_board()}
    for k, img in extras.items():                  # колокольня и колодец — на 2×2 (опора — ближний угол), доска — клетка
        save(img, out, "prop_" + k, "props/" + k)
    board, places = render_notice_board_ui()
    save(board, out, "image_notice_board", "images/notice_board")
    (out / "notice_board_pages.json").write_text(json.dumps(dict(size=list(board.size), **places)) + "\n",
                                                 encoding="utf-8")
    print("  колокольня, колодец, доска объявлений; места текста на доске: %s" % places)
    if args.preview:
        preview(maps, sprites, args.location, Path(args.preview), extras=extras)
        print("Проверка: %s" % args.preview)
    return 0


if __name__ == "__main__":
    sys.exit(main())
