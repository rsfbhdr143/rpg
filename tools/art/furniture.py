"""Обстановка домов тем же способом, что и дома (tools/art/buildings.py): маленькие 3D-сцены в изометрии 2:1.

Мешки, сено, верстак, горшки, ткацкий станок, котёл, стойка со шкурой и рыбой, печь, сушёные травы — каждый на
одну клетку, в том же свете, обводке и масштабе, что и дома (1 пиксель картинки = 1 пиксель мира). У котла и печи
по 4 кадра: огонь мерцает. Пишет art/inbox/furniture/prop_<id>.png + .art.json (привязка props/<id>); дальше
python tools/art/import_art.py.

    python tools/art/furniture.py
    python tools/art/furniture.py --preview art/review/furniture.png
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).parent))
from buildings import LIGHT, OUTLINE, ROOT, STONE, Scene, box, flat, footprint_scene, noise, seed_of, shade, stone  # noqa: E402

WOOD = (116, 80, 50)
DARK_WOOD = (78, 54, 34)
IRON = (70, 70, 76)


def wood(seed: int, base=WOOD, along: str = "u"):
    """Доска: волокна вдоль u, v или вверх (z)."""
    def sh(u, v, z):
        s = u if along == "u" else v if along == "v" else z / 16
        a = np.floor((v if along == "u" else u) * 24 + z / 2) if along != "z" else np.floor((u - v) * 24)
        return shade(base, 0.84 + 0.26 * noise(a, np.floor(s * 5), seed))
    return sh


def cylinder(sc: Scene, cu, cv, r, z0, z1, shader, n: int = 14, r1=None, top=None):
    """Многогранный цилиндр или усечённый конус (r внизу, r1 вверху) по оси z; top — шейдер крышки."""
    r1 = r if r1 is None else r1
    for i in range(n):
        a0, a1 = 2 * math.pi * i / n, 2 * math.pi * (i + 1) / n
        nx, ny = math.cos((a0 + a1) / 2), math.sin((a0 + a1) / 2)
        if nx + ny < -0.7:                       # задняя сторона всё равно закрыта
            continue
        k = 0.62 + 0.38 * max(0.0, nx * 0.85 + ny * 0.55)
        sc.poly([(cu + r * math.cos(a0), cv + r * math.sin(a0), z0), (cu + r * math.cos(a1), cv + r * math.sin(a1), z0),
                 (cu + r1 * math.cos(a1), cv + r1 * math.sin(a1), z1), (cu + r1 * math.cos(a0), cv + r1 * math.sin(a0), z1)],
                shader, k)
    if top is not None and r1 > 0:
        sc.poly([(cu + r1 * math.cos(2 * math.pi * i / n), cv + r1 * math.sin(2 * math.pi * i / n), z1) for i in range(n)],
                top, LIGHT["up"])


def lathe(sc: Scene, cu, cv, profile, shader, top=None, n: int = 14):
    """Тело вращения по профилю [(r, z), ...] снизу вверх: горшок, котёл, купол печи."""
    for (r0, z0), (r1, z1) in zip(profile, profile[1:]):
        cylinder(sc, cu, cv, r0, z0, z1, shader, n, r1)
    if top is not None:
        r, z = profile[-1]
        cylinder(sc, cu, cv, r, z, z, flat((0, 0, 0)), n, r, top)


def cell() -> Scene:
    return footprint_scene(1, 1, 40)


def px(d: ImageDraw.ImageDraw, sc: Scene, p, dx=0, dy=0):
    x, y = sc.screen(p)
    return int(round(x)) + dx, int(round(y)) + dy


# --- Предметы ------------------------------------------------------------------------------------------------

def sacks() -> Image.Image:
    sc = cell()
    seed = seed_of("sacks")

    def burlap(tone, band=None):
        def sh(u, v, z):
            weave = noise(np.floor((u - v) * 40), np.floor(z), seed)
            col = shade(tone, 0.86 + 0.2 * weave)
            if band is not None:
                col[(z > 5) & (z < 7)] = band
            return col
        return sh
    for cu, cv, hz, tone, band in ((0.36, 0.38, 13, (196, 176, 132), None), (0.66, 0.4, 11, (182, 162, 120), None),
                                   (0.52, 0.68, 12, (204, 186, 142), (150, 54, 44))):
        sh = burlap(tone, band)
        lathe(sc, cu, cv, [(0.12, 0), (0.15, 3), (0.15, hz - 4), (0.12, hz - 1), (0.05, hz + 1)], sh)
        cylinder(sc, cu, cv, 0.04, hz + 1, hz + 3, flat(shade(tone, 0.7)), 8)            # завязка
        cylinder(sc, cu, cv, 0.05, hz + 3, hz + 5, sh, 8, 0.07)                           # хохолок
    return sc.image()


def hay() -> Image.Image:
    sc = cell()
    seed = seed_of("hay")

    def straw(along):
        def sh(u, v, z):
            s, t = (u, v) if along == "u" else (v, u)
            k = np.floor((t + z / 16) * 40)
            col = shade((206, 172, 86), 0.8 + 0.3 * noise(k, np.floor(s * 6), seed))
            col[noise(k, np.floor(s * 3), seed + 1) > 0.9] = (150, 118, 52)
            band = (np.abs(s - 0.33) < 0.025) | (np.abs(s - 0.67) < 0.025)
            col[band] = (96, 70, 40)
            return col
        return sh
    box(sc, (0.1, 0.22, 0), (0.9, 0.78, 10), straw("u"))
    box(sc, (0.24, 0.12, 10), (0.76, 0.88, 18), straw("v"))
    img = sc.image()
    d = ImageDraw.Draw(img)
    for i in range(7):                                                        # торчащие соломинки
        u = 0.15 + 0.7 * noise(i, 1, seed)
        x, y = px(d, sc, (u, 0.8, 1 + 7 * noise(i, 2, seed)))
        d.line([(x, y), (x + (2 if i % 2 else -2), y + 2)], fill=(222, 190, 100))
    return img


def workbench() -> Image.Image:
    sc = cell()
    seed = seed_of("workbench")
    top = wood(seed, (138, 98, 60))
    leg = wood(seed + 1, DARK_WOOD, "z")
    for lu, lv in ((0.1, 0.3), (0.82, 0.3), (0.1, 0.62), (0.82, 0.62)):
        box(sc, (lu, lv, 0), (lu + 0.08, lv + 0.08, 13), leg)
    box(sc, (0.12, 0.32, 4), (0.88, 0.68, 5.5), wood(seed + 2, DARK_WOOD))           # полка
    box(sc, (0.16, 0.36, 5.5), (0.5, 0.6, 8), wood(seed + 3, (150, 112, 70)))         # доски на полке
    box(sc, (0.06, 0.28, 13), (0.94, 0.72, 16), top)
    box(sc, (0.8, 0.62, 12), (0.94, 0.76, 19), flat(IRON), top_col=shade(IRON, 1.4))  # тиски
    sc.poly([(0.2, 0.45, 16.2), (0.55, 0.45, 16.2), (0.55, 0.58, 16.2), (0.24, 0.58, 16.2)],
            lambda u, v, z: shade((176, 178, 184), 0.9 + 0.2 * (np.floor(u * 40) % 2)), LIGHT["up"])  # пила
    box(sc, (0.14, 0.45, 16), (0.22, 0.58, 18), wood(seed + 4, (90, 60, 36)))         # ручка пилы
    box(sc, (0.6, 0.34, 16), (0.76, 0.38, 17), wood(seed + 5, (150, 110, 64)))        # рукоять молотка
    box(sc, (0.74, 0.31, 16), (0.79, 0.41, 19), flat(IRON), top_col=shade(IRON, 1.4))
    img = sc.image()
    d = ImageDraw.Draw(img)
    for i in range(5):                                                        # стружка на полу
        x, y = px(d, sc, (0.2 + 0.6 * noise(i, 3, seed), 0.75 + 0.15 * noise(i, 4, seed), 0))
        d.point((x, y), fill=(212, 176, 110))
    return img


def pots() -> Image.Image:
    sc = cell()
    seed = seed_of("pots")

    def clay(tone, zb):
        def sh(u, v, z):
            col = shade(tone, 0.95 + 0.08 * noise(np.floor((u - v) * 16), np.floor(z / 3), seed))
            col[np.abs(z - zb) < 0.6] = shade(tone, 1.25)                       # светлый поясок
            return col
        return sh
    inner = flat((40, 26, 18))
    for cu, cv, s, tone in ((0.3, 0.32, 1.0, (190, 108, 64)), (0.72, 0.36, 0.8, (170, 96, 58)),
                            (0.46, 0.72, 0.7, (204, 150, 96))):
        s *= 1.2
        prof = [(0.09 * s, 0), (0.15 * s, 3 * s), (0.16 * s, 7 * s), (0.1 * s, 11 * s), (0.07 * s, 12 * s),
                (0.09 * s, 13.5 * s)]
        lathe(sc, cu, cv, prof, clay(tone, 8 * s), top=inner)
    return sc.image()


def loom() -> Image.Image:
    sc = cell()
    seed = seed_of("loom")
    frame = wood(seed, (104, 70, 42), "z")
    beam = wood(seed + 1, (124, 86, 52))
    v0, v1 = 0.4, 0.5
    for u0 in (0.1, 0.82):
        box(sc, (u0, v0, 0), (u0 + 0.08, v1, 27), frame)
    box(sc, (0.08, v0, 24), (0.92, v1, 27), beam)
    box(sc, (0.08, v0, 3), (0.92, v1, 6), beam)

    def warp(u, v, z):
        col = np.tile(np.asarray((206, 196, 170), float), (len(u), 1))
        thread = (np.floor(u * 64) % 2) == 0
        col[thread] = (168, 156, 128)
        woven = z < 17
        stripes = np.floor(z / 2).astype(int) % 4
        palette = np.asarray([(150, 50, 46), (196, 160, 80), (226, 214, 184), (70, 86, 120)], float)
        col[woven] = palette[stripes[woven]] * (0.9 + 0.1 * thread[woven])[..., None]
        return col
    sc.poly([(0.18, v1 + 0.005, 6), (0.82, v1 + 0.005, 6), (0.82, v1 + 0.005, 24), (0.18, v1 + 0.005, 24)], warp, 1.0)
    for u0 in (0.14, 0.8):                                                    # ножки грудного вала
        box(sc, (u0, 0.66, 0), (u0 + 0.06, 0.72, 7), frame)
    box(sc, (0.12, 0.64, 5), (0.88, 0.74, 7.5), lambda u, v, z: warp(u, v, z * 0 + 10))  # ткань на валу
    box(sc, (0.15, 0.52, 17), (0.85, 0.56, 19), beam)                          # батан
    return sc.image()


def cauldron(frames: int = 4) -> list[Image.Image]:
    sc = cell()
    seed = seed_of("cauldron")
    for i, (a, r) in enumerate(((0.3, 0.38), (2.4, 0.36), (4.3, 0.37))):      # камни очага
        cu, cv = 0.5 + r * math.cos(a), 0.5 + r * math.sin(a)
        box(sc, (cu - 0.08, cv - 0.07, 0), (cu + 0.08, cv + 0.07, 4 + i % 2),
            lambda u, v, z, i=i: stone(u + v, z, seed + i, shade(STONE, 0.85)))

    def iron(u, v, z):
        col = shade(IRON, 0.75 + 0.2 * noise(np.floor((u - v) * 20), np.floor(z / 2), seed))
        col[np.abs(z - 12.5) < 0.7] = shade(IRON, 1.35)                       # блик у края
        return col
    lathe(sc, 0.5, 0.5, [(0.16, 3), (0.27, 6), (0.29, 10), (0.25, 13), (0.27, 14)], iron,
          top=lambda u, v, z: shade((86, 140, 60), 0.85 + 0.25 * noise(np.floor(u * 20), np.floor(v * 20), seed)))
    base = sc.image()
    out = []
    cx, cy = (int(round(c)) for c in sc.screen((0.5, 0.5, 2)))
    sx, sy = (int(round(c)) for c in sc.screen((0.5, 0.5, 14)))
    for f in range(frames):
        img = base.copy()
        d = ImageDraw.Draw(img)
        for k in range(4):                                                    # языки огня под котлом
            fx = cx - 7 + k * 5 + (f + k) % 2
            fh = 3 + (f * 3 + k * 5) % 3
            d.polygon([(fx - 2, cy + 5), (fx + 2, cy + 5), (fx, cy + 5 - fh)], fill=(232, 110, 36))
            d.line([(fx, cy + 4), (fx, cy + 6 - fh)], fill=(255, 200, 96))
        for k in range(2):                                                    # пузыри
            bx = sx - 4 + ((f * 5 + k * 7) % 9)
            by = sy - 1 + ((f + k) % 2)
            d.point((bx, by), fill=(170, 220, 120))
            d.point((bx, by - 1), fill=(120, 180, 90))
        out.append(img)
    return out


def rack() -> Image.Image:
    sc = cell()
    seed = seed_of("rack")
    post = wood(seed, DARK_WOOD, "z")
    for u0 in (0.1, 0.84):
        box(sc, (u0, 0.46, 0), (u0 + 0.06, 0.52, 25), post)
    box(sc, (0.08, 0.46, 22), (0.92, 0.52, 24), wood(seed + 1, (110, 76, 46)))

    def hide(u, v, z):
        col = shade((184, 140, 96), 0.88 + 0.22 * noise(np.floor(u * 40), np.floor(z), seed))
        col[noise(np.floor(u * 12), np.floor(z / 3), seed + 3) > 0.8] = (128, 92, 60)
        return col
    vv = 0.53
    sc.poly([(0.2, vv, 22), (0.5, vv, 22), (0.48, vv, 14), (0.52, vv, 8), (0.36, vv, 5), (0.22, vv, 9), (0.18, vv, 15)],
            hide, 1.0)
    img = sc.image()
    d = ImageDraw.Draw(img)
    for k, u in enumerate((0.6, 0.69, 0.78)):                                 # рыба на верёвочках
        x, y = px(d, sc, (u, vv, 22))
        ln = 4 + k % 2 * 2
        d.line([(x, y), (x, y + ln)], fill=(150, 130, 100))
        d.polygon([(x - 1, y + ln), (x + 1, y + ln), (x + 2, y + ln + 6), (x, y + ln + 9), (x - 2, y + ln + 6)],
                  fill=(150, 160, 168), outline=OUTLINE)
        d.point((x, y + ln + 2), fill=(30, 30, 36))
    return img


def oven(frames: int = 4) -> list[Image.Image]:
    sc = cell()
    seed = seed_of("oven")
    box(sc, (0.1, 0.12, 0), (0.9, 0.88, 6), lambda u, v, z: stone(u + v, z, seed, shade(STONE, 0.9)),
        top_col=shade(STONE, 0.8))

    def clay(u, v, z):
        col = shade((168, 140, 110), 0.85 + 0.2 * noise(np.floor((u - v) * 24), np.floor(z / 2), seed))
        col[noise(np.floor((u - v) * 50), np.floor(z), seed + 1) > 0.93] = (110, 88, 70)        # трещинки
        return col
    lathe(sc, 0.5, 0.5, [(0.37, 6), (0.38, 9), (0.35, 12.5), (0.28, 15.5), (0.16, 17.5), (0.0, 18.5)], clay, n=16)
    cylinder(sc, 0.3, 0.3, 0.07, 12, 24, lambda u, v, z: stone(u + v, z, seed + 2, (120, 108, 96)), 8,
             top=flat((30, 24, 22)))                                          # дымоход сзади
    t = 0.37 / math.sqrt(2)
    fu = fv = 0.5 + t + 0.01

    def mouth(off):
        return [(fu + off, fv - off, 6.2), (fu - off, fv + off, 6.2), (fu - off, fv + off, 10.5),
                (fu - off * 0.5, fv + off * 0.5, 12.5), (fu, fv, 13.2), (fu + off * 0.5, fv - off * 0.5, 12.5),
                (fu + off, fv - off, 10.5)]
    sc.poly(mouth(0.12), flat((120, 96, 76)), 0.9)
    sc.poly([(x + 0.01, y + 0.01, z) for x, y, z in mouth(0.09)], flat((24, 16, 12)), 1.0)
    base = sc.image()
    mx, my = (int(round(c)) for c in sc.screen((fu, fv, 7)))
    out = []
    for f in range(frames):
        img = base.copy()
        d = ImageDraw.Draw(img)
        glow = [(170, 64, 24), (214, 96, 30), (240, 140, 50), (214, 96, 30)][f % 4]
        d.rectangle([mx - 3, my - 2, mx + 3, my], fill=glow)
        d.point((mx - 1 + f % 3, my - 3), fill=(255, 200, 100))
        d.line([(mx - 2, my + 1), (mx + 2, my + 1)], fill=(60, 30, 20))      # угли
        out.append(img)
    return out


def herbs() -> Image.Image:
    sc = cell()
    seed = seed_of("herbs")
    post = wood(seed, DARK_WOOD, "z")
    for u0 in (0.14, 0.8):
        box(sc, (u0, 0.44, 0), (u0 + 0.06, 0.5, 22), post)
    box(sc, (0.12, 0.44, 20), (0.88, 0.5, 22), wood(seed + 1, (110, 76, 46)))

    def basket(u, v, z):
        k = (np.floor((u - v) * 30) + np.floor(z / 2)) % 2
        return shade((150, 112, 62), 0.8 + 0.2 * k)
    cylinder(sc, 0.55, 0.72, 0.14, 0, 5, basket, 12, 0.16, top=flat((92, 116, 56)))
    img = sc.image()
    d = ImageDraw.Draw(img)
    cols = [(92, 120, 58), (132, 112, 60), (110, 70, 80), (80, 100, 50), (150, 120, 70)]
    for k in range(5):
        x, y = px(d, sc, (0.2 + k * 0.14, 0.51, 20))
        c = cols[(k * 3 + 1) % len(cols)]
        dark = tuple(int(q) for q in shade(c, 0.55))
        ln = 2 + k % 2
        d.line([(x, y), (x, y + ln)], fill=(60, 44, 30))
        d.polygon([(x - 1, y + ln), (x + 1, y + ln), (x + 3, y + ln + 8), (x - 3, y + ln + 8)], fill=c, outline=dark)
        d.line([(x - 1, y + ln + 2), (x + 1, y + ln + 2)], fill=(150, 120, 70))
    for k in range(4):                                                        # цветки в корзине
        x, y = px(d, sc, (0.48 + 0.05 * k, 0.68 + 0.03 * (k % 2), 5.5))
        d.point((x, y - 1), fill=[(210, 120, 150), (224, 186, 70), (196, 60, 52), (230, 230, 220)][k])
    return img


ITEMS = {"sacks": sacks, "hay": hay, "workbench": workbench, "pots": pots, "loom": loom, "cauldron": cauldron,
         "rack": rack, "oven": oven, "herbs": herbs}


def save(frames: list[Image.Image], out: Path, item: str) -> Image.Image:
    """Кадры в одну полосу; подсказка: привязка props/<item>, по клетке, 4 кадра — анимация idle."""
    out.mkdir(parents=True, exist_ok=True)
    w, h = frames[0].size
    strip = Image.new("RGBA", (w * len(frames), h))
    for i, f in enumerate(frames):
        strip.alpha_composite(f, (i * w, 0))
    strip.save(out / ("prop_%s.png" % item))
    hint = {"id": "prop_" + item, "bind": "props/" + item, "kind": "image", "cols": len(frames), "rows_count": 1}
    if len(frames) > 1:
        hint["fps"] = 6
    (out / ("prop_%s.art.json" % item)).write_text(json.dumps(hint, ensure_ascii=False) + "\n", encoding="utf-8")
    return frames[0]


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=str(ROOT / "art" / "inbox" / "furniture"))
    ap.add_argument("--preview", default="", help="все предметы рядом, крупно (art/review/furniture.png)")
    args = ap.parse_args(argv)
    firsts = []
    for item, fn in ITEMS.items():
        res = fn()
        frames = res if isinstance(res, list) else [res]
        firsts.append(save(frames, Path(args.out), item))
        print("  props/%s: %d кадр(а)" % (item, len(frames)))
    if args.preview:
        tiles = [f.crop(f.getbbox()) for f in firsts]
        k = 4
        W = sum(t.width * k + 24 for t in tiles) + 24
        H = max(t.height for t in tiles) * k + 40
        sheet = Image.new("RGBA", (W, H), (62, 70, 52, 255))
        x = 24
        for t in tiles:
            big = t.resize((t.width * k, t.height * k), Image.NEAREST)
            sheet.alpha_composite(big, (x, H - 20 - big.height))
            x += big.width + 24
        Path(args.preview).parent.mkdir(parents=True, exist_ok=True)
        sheet.save(args.preview)
        print("Проверка: %s" % args.preview)
    return 0


if __name__ == "__main__":
    sys.exit(main())
