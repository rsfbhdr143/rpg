"""Картинки через Nano Banana (Gemini): код рисует примерную форму, Gemini её перерисовывает в общем стиле.

Как это работает:
  1. `python tools/art/nano.py sheets` — эталоны кодом, листами: дома из buildings.py (с дверями), манекены
     одного роста для персонажей, заготовки портретов, сетки значков, мебель и предметы, раскладка для интерфейса.
     Пишет в art/nano/jobs/: картинки листов, style.jpg (образец стиля) и jobs.json — запрос к Gemini на каждый лист.
  2. На ПК сессия Claude открывает gemini.google.com, к каждому листу прикрепляет его картинку и образец стиля,
     отправляет запрос из jobs.json и сохраняет ответ в art/nano/out/<лист>.jpg.
  3. `python tools/art/nano.py cut` — режет ответы обратно на картинки по раскладке (art/nano/jobs/layout.json),
     убирает фон и кладёт во входящие art/inbox/nano/ вместе с подсказками *.art.json. Дальше — import_art.py.

Дом из Gemini встаёт на карту, потому что лист — это те же картинки домов из кода: тот же холст, те же двери и окна;
Gemini меняет только рисунок, а вырезается ровно прямоугольник исходной картинки.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
JOBS = ROOT / "art" / "nano" / "jobs"
OUT = ROOT / "art" / "nano" / "out"
INBOX = ROOT / "art" / "inbox" / "nano"
MAGENTA = (255, 0, 255)
WHITE = (255, 255, 255)
SHEET_SIDE = 1400        # длинная сторона листа для Gemini

STYLE = ("hand-drawn coloured engraving: fine black ink hatching and cross-hatching over muted watercolour washes, "
         "like an old hand-coloured woodcut book illustration, dark-fantasy RPG in the spirit of Divinity: Original Sin, "
         "muted earthy palette (umber, ochre, moss green, slate blue, ash grey), soft light from the upper left")
STYLE_NOTE = "Match the drawing style, line weight, hatching and palette of image 2 exactly."


# --- Общие мелочи ---------------------------------------------------------------------------------------------

def grid_sheet(cells: list[Image.Image], cols: int, gap: int, bg) -> tuple[Image.Image, list[list[int]]]:
    """Картинки сеткой: ширина колонки и высота строки — по самой большой; низ к низу, по центру."""
    rows = math.ceil(len(cells) / cols)
    cw = [max((cells[r * cols + c].width for r in range(rows) if r * cols + c < len(cells)), default=0)
          for c in range(cols)]
    rh = [max(cells[r * cols + c].height for c in range(cols) if r * cols + c < len(cells)) for r in range(rows)]
    W, H = sum(cw) + gap * (cols + 1), sum(rh) + gap * (rows + 1)
    sheet = Image.new("RGB", (W, H), bg)
    rects = []
    y = gap
    for r in range(rows):
        x = gap
        for c in range(cols):
            k = r * cols + c
            if k < len(cells):
                im = cells[k]
                px, py = x + (cw[c] - im.width) // 2, y + rh[r] - im.height
                sheet.paste(im, (px, py), im if im.mode == "RGBA" else None)
                rects.append([px, py, px + im.width, py + im.height])
            x += cw[c] + gap
        y += rh[r] + gap
    return sheet, rects


def upscale(sheet: Image.Image) -> tuple[Image.Image, int]:
    k = max(1, SHEET_SIDE // max(sheet.size))
    return sheet.resize((sheet.width * k, sheet.height * k), Image.NEAREST), k


def on_bg(im: Image.Image, bg) -> Image.Image:
    c = Image.new("RGBA", im.size, (*bg, 255))
    c.alpha_composite(im.convert("RGBA"))
    return c


def fit(im: Image.Image, box: tuple[int, int]) -> Image.Image:
    s = min(box[0] / im.width, box[1] / im.height)
    return im.resize((max(1, round(im.width * s)), max(1, round(im.height * s))), Image.LANCZOS)


# --- Манекены: один рост для всех людей ------------------------------------------------------------------------
# Холст персонажа 144×200 (как рамка юнита в игре 0.9 × 1.25 клетки), ступни на y=194, макушка взрослого на y=44:
# над головой остаётся место для шапок и оружия, поэтому после вписывания в рамку все люди одного роста.

FIG_W, FIG_H, GROUND, TOP = 144, 200, 196, 44
FIG_K = 1.13             # после рисования манекен растягивается от ступней: макушка взрослого на y≈24
SKIN, BACK, LINE = (196, 196, 196), (160, 160, 160), (60, 60, 60)


def figure(kind: str = "man") -> Image.Image:
    im = _figure(kind)
    big = im.resize((round(FIG_W * FIG_K), round(FIG_H * FIG_K)), Image.LANCZOS)
    ox, oy = round(72 * FIG_K - 72), round(GROUND * FIG_K - GROUND)
    return big.crop((ox, oy, ox + FIG_W, oy + FIG_H))


def front_figure() -> Image.Image:
    """Человек анфас для силуэта снаряжения: руки чуть в стороны, ноги вместе."""
    S = 4
    im = Image.new("RGBA", (216 * S, 300 * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    P = lambda pts: [(x * S, y * S) for x, y in pts]
    kw = {"fill": SKIN, "outline": LINE, "width": S}
    for sgn in (-1, 1):
        d.polygon(P([(108 + sgn * 40, 76), (108 + sgn * 52, 82), (108 + sgn * 70, 168), (108 + sgn * 60, 172)]), **kw)
        d.polygon(P([(108 + sgn * 4, 170), (108 + sgn * 24, 170), (108 + sgn * 22, 284), (108 + sgn * 8, 284)]), **kw)
    d.polygon(P([(68, 74), (148, 74), (136, 160), (80, 160)]), **kw)
    d.polygon(P([(78, 156), (138, 156), (134, 178), (82, 178)]), **kw)
    d.rectangle(P([(100, 56), (116, 76)]), **kw)
    d.ellipse(P([(88, 12), (128, 60)]), **kw)
    return im.resize((216, 300), Image.LANCZOS)


def _figure(kind: str = "man") -> Image.Image:
    im = Image.new("RGBA", (FIG_W * 4, FIG_H * 4), (0, 0, 0, 0))   # рисуем вчетверо крупнее, потом уменьшаем
    d = ImageDraw.Draw(im)
    S = 4

    def P(pts, scale=1.0, lift=0.0, cx=72.0):
        return [((cx + (x - cx) * scale) * S, (GROUND - (GROUND - y) * scale - lift) * S) for x, y in pts]

    def poly(pts, col, **kw):
        d.polygon(P(pts, **kw), fill=col, outline=LINE, width=2 * S // 2)

    def ell(x0, y0, x1, y1, col, **kw):
        (a, b), (c, e) = P([(x0, y0), (x1, y1)], **kw)
        d.ellipse([min(a, c), min(b, e), max(a, c), max(b, e)], fill=col, outline=LINE, width=S)

    if kind in ("wolf", "goat"):
        goat = kind == "goat"
        sc = 0.8 if goat else 1.0
        kw = {"scale": sc}
        poly([(36, 186), (44, 186), (46, 150), (38, 150)], BACK, **kw)          # дальние ноги
        poly([(92, 186), (100, 186), (100, 150), (92, 150)], BACK, **kw)
        ell(26, 126, 108, 166, SKIN, **kw)                                       # туловище
        poly([(28, 186), (37, 186), (40, 152), (30, 152)], SKIN, **kw)          # ближние ноги
        poly([(100, 186), (109, 186), (108, 152), (99, 152)], SKIN, **kw)
        poly([(98, 136), (112, 108), (124, 112), (116, 140)], SKIN, **kw)       # шея
        ell(108, 98, 140, 122, SKIN, **kw)                                       # голова
        if goat:
            poly([(116, 100), (110, 82), (118, 84), (122, 100)], BACK, **kw)    # рога
        else:
            poly([(116, 100), (114, 86), (122, 98)], SKIN, **kw)                # уши
            poly([(28, 136), (8, 150), (12, 156), (30, 146)], SKIN, **kw)       # хвост
        return im.resize((FIG_W, FIG_H), Image.LANCZOS)
    if kind == "dummy":
        poly([(68, 194), (76, 194), (76, 96), (68, 96)], BACK)
        poly([(40, 100), (104, 100), (104, 108), (40, 108)], BACK)
        ell(56, 104, 88, 152, SKIN)
        ell(58, 66, 86, 96, SKIN)
        return im.resize((FIG_W, FIG_H), Image.LANCZOS)

    sc, head_k, belly, ears, dress = 1.0, 1.0, 0, False, False
    if kind == "child":
        sc = 0.72
    elif kind == "goblin":
        sc, head_k, ears = 0.62, 1.45, True
    elif kind == "big_goblin":
        sc, head_k, ears, belly = 0.8, 1.3, True, 12
    elif kind == "stout":
        belly = 8
    elif kind == "woman":
        dress = True
    kw = {"scale": sc}
    sh = 17 + belly * 0.6
    wa = 11 + belly
    # дальняя рука и нога темнее
    poly([(72 - sh, 70), (72 - sh + 7, 72), (72 - sh + 2, 124), (72 - sh - 4, 122)], BACK, **kw)
    if not dress:
        poly([(60, 122), (69, 122), (66, 186), (59, 186)], BACK, **kw)
        ell(58, 184, 72, 194, BACK, **kw)
    # туловище
    poly([(72 - sh, 68), (72 + sh, 68), (72 + wa, 112), (72 - wa, 112)], SKIN, **kw)
    if dress:
        poly([(72 - wa, 108), (72 + wa, 108), (98, 188), (46, 188)], SKIN, **kw)
        ell(66, 186, 80, 194, SKIN, **kw)
    else:
        poly([(72 - wa - 2, 110), (72 + wa + 2, 110), (72 + wa, 126), (72 - wa, 126)], SKIN, **kw)
        poly([(73, 122), (84, 122), (82, 186), (75, 186)], SKIN, **kw)
        ell(74, 184, 92, 194, SKIN, **kw)
    # ближняя рука
    poly([(72 + sh - 6, 70), (72 + sh + 2, 72), (72 + sh + 4, 124), (72 + sh - 3, 124)], SKIN, **kw)
    ell(72 + sh - 4, 120, 72 + sh + 6, 130, SKIN, **kw)
    # шея и голова (у гоблина голова крупнее)
    poly([(69, 62), (77, 62), (77, 70), (69, 70)], SKIN, **kw)
    hr = 10 * head_k
    cy = TOP + hr if sc == 1.0 else GROUND - (GROUND - (TOP + 10)) * 1.0
    cx, cyh = 74.0, 52.0
    head = [(cx - 8 * head_k, cyh - hr), (cx + 8 * head_k, cyh + hr)]
    lift = (hr - 10) * 0.9
    ell(head[0][0], head[0][1] - lift / sc, head[1][0], head[1][1] - lift / sc, SKIN, **kw)
    poly([(cx + 7 * head_k, cyh - 2), (cx + 11 * head_k, cyh + 2), (cx + 7 * head_k, cyh + 4)], SKIN, **kw)  # нос вправо
    if ears:
        poly([(cx - 6, cyh - 4 - lift / sc), (cx - 24, cyh - 14 - lift / sc), (cx - 8, cyh + 4 - lift / sc)], SKIN, **kw)
    return im.resize((FIG_W, FIG_H), Image.LANCZOS)


def bust(kind: str = "human") -> Image.Image:
    """Заготовка портрета 132×132: тёмный фон и серый бюст в три четверти, лицом вправо."""
    S = 4
    im = Image.new("RGB", (132 * S, 132 * S), (43, 33, 25))
    d = ImageDraw.Draw(im)
    if kind == "blank":
        return im.resize((132, 132), Image.LANCZOS)
    big = kind == "goblin"
    d.pieslice([10 * S, 92 * S, 122 * S, 190 * S], 180, 360, fill=SKIN, outline=LINE, width=S)
    d.rectangle([58 * S, 76 * S, 78 * S, 100 * S], fill=SKIN, outline=LINE, width=S)
    rx, ry = (30, 32) if big else (22, 28)
    d.ellipse([(70 - rx) * S, (52 - ry) * S, (70 + rx) * S, (52 + ry) * S], fill=SKIN, outline=LINE, width=S)
    d.polygon([(90 * S, 50 * S), (98 * S, 60 * S), (89 * S, 62 * S)], fill=SKIN, outline=LINE)
    if big:
        d.polygon([(46 * S, 44 * S), (12 * S, 30 * S), (44 * S, 60 * S)], fill=SKIN, outline=LINE)
    return im.resize((132, 132), Image.LANCZOS)


# --- Предметы, которые код рисует заново ----------------------------------------------------------------------

def chest() -> Image.Image:
    S = 4
    im = Image.new("RGBA", (120 * S, 100 * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    wood, side, iron = (132, 88, 50), (104, 68, 40), (70, 70, 74)
    a, b, c, e = (12, 52), (66, 79), (108, 58), (54, 31)          # нижний ромб: лево, низ, право, верх
    up = 28
    P = lambda pts: [(x * S, y * S) for x, y in pts]
    d.polygon(P([a, b, (b[0], b[1] - up), (a[0], a[1] - up)]), fill=wood, outline=LINE)
    d.polygon(P([b, c, (c[0], c[1] - up), (b[0], b[1] - up)]), fill=side, outline=LINE)
    for t in (0.18, 0.82):                                          # железные полосы
        x0, y0 = a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t
        d.line(P([(x0, y0), (x0, y0 - up)]), fill=iron, width=4 * S)
    lid = [(a[0], a[1] - up), (b[0], b[1] - up), (c[0], c[1] - up), (e[0], e[1] - up)]
    d.polygon(P([(a[0], a[1] - up), (b[0], b[1] - up), (b[0] + 2, b[1] - up - 16), (a[0] + 2, a[1] - up - 16)]), fill=wood, outline=LINE)
    d.polygon(P([(b[0], b[1] - up), (c[0], c[1] - up), (c[0] - 2, c[1] - up - 16), (b[0] + 2, b[1] - up - 16)]), fill=side, outline=LINE)
    d.polygon(P([(a[0] + 2, a[1] - up - 16), (b[0] + 2, b[1] - up - 16), (c[0] - 2, c[1] - up - 16), (e[0], e[1] - up - 16)]),
              fill=(150, 104, 62), outline=LINE)
    mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2 - up + 2
    d.rectangle(P([(mx - 4, my - 4), (mx + 4, my + 6)]), fill=(200, 170, 90), outline=LINE)
    return im.resize((120, 100), Image.LANCZOS)


def loot_bag() -> Image.Image:
    S = 4
    im = Image.new("RGBA", (90 * S, 90 * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    burlap = (150, 118, 76)
    d.ellipse([12 * S, 36 * S, 78 * S, 86 * S], fill=burlap, outline=LINE, width=S)
    d.polygon([(32 * S, 40 * S), (58 * S, 40 * S), (52 * S, 22 * S), (38 * S, 22 * S)], fill=burlap, outline=LINE)
    d.line([(34 * S, 30 * S), (56 * S, 30 * S)], fill=(90, 62, 36), width=3 * S)
    d.polygon([(38 * S, 22 * S), (30 * S, 12 * S), (44 * S, 18 * S), (52 * S, 10 * S), (52 * S, 22 * S)], fill=burlap, outline=LINE)
    return im.resize((90, 90), Image.LANCZOS)


def tree(dead: bool = False, bush_only: bool = False) -> Image.Image:
    S = 4
    W, H = (120, 90) if bush_only else (140, 200)
    im = Image.new("RGBA", (W * S, H * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    bark = (104, 82, 62) if not dead else (92, 84, 76)
    P = lambda pts: [(x * S, y * S) for x, y in pts]
    if not bush_only:
        d.polygon(P([(60, 196), (82, 196), (76, 110), (66, 110)]), fill=bark, outline=LINE)
        d.polygon(P([(52, 198), (90, 198), (82, 186), (60, 186)]), fill=bark, outline=LINE)   # корни
        if dead:
            for (x0, y0, x1, y1, w) in [(70, 120, 30, 70, 6), (72, 112, 112, 60, 6), (50, 92, 40, 50, 4),
                                        (96, 82, 118, 40, 4), (70, 110, 74, 30, 7), (74, 50, 92, 22, 3)]:
                d.line(P([(x0, y0), (x1, y1)]), fill=bark, width=w * S)
            return im.resize((W, H), Image.LANCZOS)
    blobs = [(10, 30, 70, 80), (50, 22, 112, 76), (28, 4, 90, 54)] if bush_only else \
        [(14, 60, 76, 124), (64, 56, 128, 120), (30, 14, 104, 84), (40, 70, 104, 132)]
    cols = [(196, 120, 50), (214, 150, 60), (180, 96, 44), (204, 136, 52)]
    for (x0, y0, x1, y1), c in zip(blobs, cols):
        d.ellipse(P([(x0, y0), (x1, y1)]), fill=c, outline=LINE, width=S)
    return im.resize((W, H), Image.LANCZOS)


def parchment(size: int = 256, seed: int = 7) -> Image.Image:
    """Бесшовный пергамент: шум, сглаженный через БПФ (он периодичен сам), крупные пятна и мелкие волокна."""
    rng = np.random.default_rng(seed)
    fy, fx = np.meshgrid(np.fft.fftfreq(size), np.fft.fftfreq(size), indexing="ij")

    def smooth(sigma_y, sigma_x):
        spec = np.fft.fft2(rng.standard_normal((size, size)))
        f = np.real(np.fft.ifft2(spec * np.exp(-(fx / sigma_x) ** 2 - (fy / sigma_y) ** 2)))
        return (f - f.mean()) / (f.std() + 1e-9)
    blot = smooth(0.012, 0.012) * 0.7 + smooth(0.03, 0.03) * 0.3       # крупные пятна
    grain = smooth(0.25, 0.25)                                         # зерно
    fiber = smooth(0.35, 0.02)                                         # волокна вдоль листа
    base = np.array([228, 210, 172], float)
    tone = blot[..., None] * np.array([9, 11, 15]) + grain[..., None] * 3 + fiber[..., None] * 2.5
    return Image.fromarray(np.clip(base - tone, 0, 255).astype(np.uint8), "RGB")


# --- Что рисуем ------------------------------------------------------------------------------------------------

UNIT_KIND = {"wolf": "wolf", "zaraza": "goat", "training_dummy": "dummy", "yurek": "child",
             "goblin_warrior": "goblin", "goblin_shaman": "goblin", "goblin_scout": "goblin", "shmyg": "goblin",
             "mukhoglot": "big_goblin", "gunter": "stout", "jacek": "stout", "tomash": "stout", "bozhena": "woman",
             "marta": "woman", "wizard": "woman", "cleric": "woman", "vetla": "woman", "hanna": "woman",
             "agata": "woman", "vlasta": "woman"}
UNIT_SHEETS = [["knight", "cleric", "ranger", "wizard"], ["tadeush", "marta", "pipin", "sych"],
               ["gunter", "vetla", "shmyg", "mukhoglot"], ["lado_body", "lado_ghost", "zaraza", "wolf"],
               ["jacek", "hanna", "savka", "agata"], ["yurek", "bolek", "zbyszek", "matey"],
               ["tomash", "vlasta", "bozhena", "stefan"], ["goblin_warrior", "goblin_shaman", "goblin_scout", "skeleton"],
               ["risen", "drowned", "training_dummy"]]
# портреты: тот же порядок, что у листов юнитов — Gemini видит готовых персонажей и рисует их же лица
PORTRAIT_SHEETS = [(0, ["knight", "cleric", "ranger", "wizard"]), (1, ["tadeush", "marta", "pipin", "sych"]),
                   (2, ["gunter", "vetla", "shmyg", "mukhoglot"]), (3, ["lado", "lado_ghost", "zaraza"]),
                   (4, ["jacek", "hanna", "savka", "agata"]), (5, ["yurek", "bolek", "zbyszek", "matey"]),
                   (6, ["tomash", "vlasta", "bozhena", "stefan"])]
PORTRAIT_FROM_UNIT = {"lado": "lado_body"}
EXTRA_UNITS = {"cleric": "a calm young priestess in white and gold vestments with a holy sun pendant, holding one simple flanged mace in her right hand",
               "lado_body": "the pale undead young nobleman Lado with empty white eyes in an elegant dark red doublet, holding one thin rapier, a crude crown of bones on his head"}
EXTRA_PORTRAITS = {
    "jacek": "a portly village headman with a short grey beard and a dark green caftan, shrewd tired eyes",
    "hanna": "a thin middle-aged weaver woman in a white headscarf, a needle behind her ear",
    "savka": "a weathered squinting fisherman with wet hair and stubble",
    "agata": "a tiny frail old widow in a black headscarf, kind sad eyes",
    "yurek": "a scruffy barefoot village boy with messy hair and a cheeky grin",
    "bolek": "a village drunkard with a red nose and a crumpled felt hat",
    "zbyszek": "a smug dandy young man in a burgundy velvet beret with a feather",
    "matey": "a grey-haired old village guard in a dented kettle helmet",
    "tomash": "a plump flour-dusted baker with a round friendly face",
    "vlasta": "a rosy-cheeked young peasant girl with a long blond braid",
    "bozhena": "a plump calm midwife in a white headscarf",
    "stefan": "a broad-shouldered young blacksmith apprentice with soot on his cheek",
}
NEW_SKILLS = {
    "regenerate": "a green sprouting vine curling around a glowing heart",
    "purify": "a clear crystal water drop with a golden sparkle washing away dark smoke",
    "smite": "a golden mace striking down with a burst of holy light",
    "shield_of_faith": "a translucent golden dome of light over a small shield",
    "healing_circle": "a ring of soft green-gold light with small healing crosses",
    "dread": "a black hooded shadow with glowing white eyes and fear lines",
    "resurrect": "a golden phoenix feather rising from a grey ash heap",
    "torch_throw": "a burning tar torch flying through the air, trailing sparks",
}
NEW_STATUSES = {"warded": "a pale golden protective rune circle", "terrified": "a pale face with wide scared eyes"}
ITEMS = {
    "order_of_bravery": "a bronze military bravery medal on a faded red ribbon",
    "own_grimoire": "a worn leather-bound grimoire with brass clasps and scribbled bookmarks",
    "lado_map": "a rolled old parchment map of burial mounds with ink marks, one circled three times",
    "copper_raven": "a copper raven amulet on a cord",
    "lamp_oil": "a corked glass bottle of golden lamp oil",
    "tar_torch": "a tar-soaked wooden torch, unlit, wrapped in black cloth",
    "juniper_bottle": "a squat green glass bottle of juniper spirit with a juniper sprig",
    "black_bead": "a single smooth black rosary bead on a short broken string",
    "smith_hammer": "a heavy blacksmith hammer with a worn wooden handle",
    "gravedigger_lantern": "an old iron gravedigger's lantern with a warm flame",
    "smoldering_seal": "a walnut-sized ember glowing orange inside like a living coal",
    "funeral_bread": "a round dark rye funeral loaf with a cross cut on top",
    "healing_brew": "a stoppered clay flask of green healing herbal brew",
    "smoked_fish": "a golden smoked fish hanging on a string",
    "honey_cake": "a small honey cake glazed with honey on a cloth",
    "wolf_fang": "a long curved white wolf fang",
    "wolf_pelt": "a folded grey wolf pelt",
    "grave_ash": "a small cloth pouch spilling grey grave ash",
    "bone_charm": "a crude charm of small bones tied with red thread",
    "river_pearl": "a single lustrous river pearl in an open mussel shell",
    "goblin_knife": "a crude jagged rusty goblin knife",
    "goblin_shield": "a small round goblin shield of planks and hide with a painted eye",
    "fly_totem": "a little stick totem with dried flies and a tiny skull",
    "mukhoglot_mask": "a cracked animal skull mask with leather straps",
    "iron_sword": "a plain iron longsword",
    "hunting_bow": "a wooden hunting longbow with its string",
    "oak_staff": "a straight oak wizard staff with a knotted top",
    "wooden_shield": "a round wooden shield with an iron boss and rim",
    "leather_cap": "a brown leather cap",
    "iron_helm": "an iron kettle helmet",
    "padded_jacket": "a quilted padded gambeson jacket",
    "chainmail": "a chainmail shirt",
    "leather_gloves": "a pair of brown leather gloves",
    "leather_boots": "a pair of tall brown leather boots",
    "wool_trousers": "a pair of grey wool trousers",
    "leather_belt": "a leather belt with a brass buckle and a small pouch",
    "silver_ring": "a silver ring with a small blue stone",
    "amber_amulet": "an amber amulet on a leather cord",
    "letter": "a folded old letter sealed with red wax",
}
PROPS_CODE = {"chest": chest, "loot_bag": loot_bag, "tree": lambda: tree(), "dead_tree": lambda: tree(dead=True),
              "bush": lambda: tree(bush_only=True)}
PROP_TEXT = {
    "chest": "a sturdy iron-bound wooden treasure chest with a domed lid and a brass lock",
    "loot_bag": "a tied burlap loot sack left on the ground where a creature fell",
    "tree": "an autumn oak with orange and yellow leaves",
    "dead_tree": "a dead leafless tree with gnarled grey-brown bark",
    "bush": "a round autumn shrub with orange and red leaves",
    "grave": "a low grave mound of earth with a small wooden cross",
    "bones": "a scattered heap of old bones and a skull",
    "hearth": "a stone hearth with a small fire",
    "altar": "a stone church altar with a white cloth and two candles",
    "counter": "a wooden tavern counter with mugs",
    "cauldron": "a black iron cauldron on a small fire",
    "hay": "a stack of golden hay",
    "herbs": "bundles of drying herbs on a wooden rack",
    "loom": "a wooden weaving loom with cloth",
    "oven": "a clay bread oven",
    "pots": "a group of clay pots and jars",
    "rack": "a wooden rack with tools",
    "sacks": "a pile of burlap grain sacks",
    "workbench": "a carpenter's workbench with tools",
}


def unit_text(uid: str, prompts: dict) -> str:
    return EXTRA_UNITS.get(uid) or prompts["units"].get(uid, uid.replace("_", " "))


def portrait_text(pid: str, prompts: dict) -> str:
    return prompts["portraits"].get(pid) or EXTRA_PORTRAITS.get(pid, pid)


def icon_text(iid: str, prompts: dict) -> str:
    for sec in ("skills", "statuses", "items"):
        if iid in prompts.get(sec, {}):
            v = prompts[sec][iid]
            return v if isinstance(v, str) else v.get("subject", iid)
    return NEW_SKILLS.get(iid) or NEW_STATUSES.get(iid) or ITEMS.get(iid) or iid.replace("_", " ")


# --- Листы ------------------------------------------------------------------------------------------------------

def build_sheets(style_src: Path) -> None:
    sys.path.insert(0, str(Path(__file__).parent))
    import buildings
    prompts = json.load(open(ROOT / "tools/art/prompts.json", encoding="utf-8"))
    sprites = json.load(open(ROOT / "data/sprites.json", encoding="utf-8"))
    catalog = json.load(open(ROOT / "art/catalog.json", encoding="utf-8"))["assets"]
    JOBS.mkdir(parents=True, exist_ok=True)
    Image.open(style_src).convert("RGB").save(JOBS / "style.jpg", quality=92)
    jobs, layout = [], {}

    def add(job: str, sheet: Image.Image, items: list[dict], prompt: str, attach_extra: list[str] = (), batch: int = 1,
            bg=WHITE):
        big, k = upscale(sheet)
        big.save(JOBS / f"{job}.png")
        layout[job] = {"base": list(sheet.size), "k": k, "bg": list(bg), "items": items}
        jobs.append({"job": job, "batch": batch, "attach": [f"{job}.png", "style.jpg", *attach_extra],
                     "prompt": prompt, "out": f"{job}.jpg"})

    # 1. Дома: те же картинки, что рисует buildings.py, листами по 2×2 (таверна и храм — со своими спутниками)
    maps = json.load(open(ROOT / "data/locations.json", encoding="utf-8"))
    houses = buildings.scene_from_cells(maps, warn=False)
    src = ROOT / "art/inbox/buildings"
    ids = [buildings.sprite_id(b["id"]) for b in houses]
    groups = [["bld_tavern", "prop_well", "prop_notice_board"], ["bld_church", "prop_bell_tower", "bld_crypt"]]
    rest = [i for i in ids if not any(i in g for g in groups)]
    rest.sort(key=lambda i: -Image.open(src / f"{i}.png").width)
    groups += [rest[j:j + 4] for j in range(0, len(rest), 4)]
    house_prompt = (
        "Image 1 is a sheet of isometric game buildings rendered as flat pixel art on a white background. "
        f"Repaint every building as a {STYLE}. {STYLE_NOTE} "
        "Keep EXACTLY each building's silhouette, size and position on the canvas, the isometric angle, the roof shape, "
        "chimneys, every window and every wooden door with its stone step in the same place. Doors must stay clearly "
        "visible. Do not add, move or remove buildings, doors, windows, signs, props, people, ground, grass or shadows. "
        "Keep the background plain flat pure white.")
    for n, g in enumerate(groups, 1):
        ims = [Image.open(src / f"{i}.png").convert("RGBA") for i in g]
        sheet, rects = grid_sheet(ims, 2 if len(g) > 1 else 1, 40, WHITE)
        items = []
        for i, r, im in zip(g, rects, ims):
            bind = "props/" + (i[5:] if i.startswith("prop_") else i)
            items.append({"id": i, "rect": r, "dir": "buildings", "mode": "house", "size": list(im.size),
                          "art": {"id": i, "bind": bind, "kind": "image", "crop": False,
                                  "pixel_box": list(im.size), "pixel_colors": 48, "doors": i.startswith("bld_")}})
        add(f"h{n:02d}", sheet, items, house_prompt, batch=1)

    # 2. Мебель, деревья и предметы на земле: эталон — нынешняя картинка или новая форма из кода
    prop_ids = [k for k in sprites["props"] if not k.startswith("bld_") and k not in
                ("bell_tower", "well", "notice_board", "lado_tracks", "fresh_grave")] + ["loot_bag"]
    cell = (200, 200)
    pcells, pitems = [], []
    for pid in prop_ids:
        sid = sprites["props"].get(pid, "prop_" + pid)
        if pid in PROPS_CODE:
            im = PROPS_CODE[pid]()
        else:
            found = [p for p in (ROOT / "art/inbox").rglob(f"{sid}.*") if p.suffix in (".png", ".webp")]
            if not found:
                print("  ! нет картинки для", pid)
                continue
            im = Image.open(found[0]).convert("RGBA")
            bb = im.getbbox()
            im = im.crop(bb) if bb else im
        fr = catalog.get(sid, {}).get("frame") or ([16, 14] if pid == "loot_bag" else [32, 32])
        pcells.append(fit(im, cell))
        pitems.append({"id": sid, "pid": pid, "dir": "props", "mode": "cut",
                       "art": {"id": sid, "bind": f"props/{pid}", "kind": "image", "pixel_box": fr}})
    per = 6
    for n, j in enumerate(range(0, len(pcells), per), 1):
        part, its = pcells[j:j + per], pitems[j:j + per]
        sheet, rects = grid_sheet(part, 3, 40, WHITE)
        for it, r in zip(its, rects):
            it["rect"] = r
        names = "; ".join(f"{k + 1}) {PROP_TEXT.get(it['pid']) or icon_text(it['pid'], prompts) if it['pid'] not in prompts['props'] else prompts['props'][it['pid']]}"
                          for k, it in enumerate(its))
        prompt = (f"Image 1 is a sheet of {len(its)} game props (left to right, top to bottom): {names}. "
                  f"Repaint each prop as a {STYLE}. {STYLE_NOTE} Keep each prop's silhouette, size, viewing angle "
                  "(isometric, seen from above at about 30 degrees) and position on the canvas; improve shapes only where "
                  "they are crude, so each reads clearly as what it is. One object per place, nothing extra, no ground "
                  "patch, no cast shadow, plain flat pure white background.")
        add(f"x{n:02d}", sheet, its, prompt, batch=1)

    # 3. Персонажи: манекены одного роста, 2×2, фон пурпурный (белые фартуки и саваны не сливаются с фоном)
    for n, g in enumerate(UNIT_SHEETS, 1):
        ims = [on_bg(figure(UNIT_KIND.get(u, "man")), MAGENTA) for u in g]
        sheet, rects = grid_sheet(ims, 2, 24, MAGENTA)
        items = [{"id": u, "rect": r, "dir": "units", "mode": "unit",
                  "art": {"id": u, "bind": f"units/{u}", "kind": "unit", "crop": False, "pixel_box": [36, 50],
                          "pixel_colors": 32}} for u, r in zip(g, rects)]
        names = "; ".join(f"{k + 1} ({['top-left', 'top-right', 'bottom-left', 'bottom-right'][k]}): {unit_text(u, prompts)}"
                          for k, u in enumerate(g))
        prompt = (f"Image 1 shows {len(g)} grey mannequins on a magenta background. Paint over each mannequin a game "
                  f"character, full body, as a {STYLE}. {STYLE_NOTE} Characters: {names}. "
                  "Keep each figure exactly as tall as its mannequin, with the feet on the same line and the head at the "
                  "same height, three-quarter view facing right, standing. Every weapon, shield or tool is held firmly in "
                  "a hand or strapped to the body; nothing floats. No ground, no shadow, no text. Keep the background "
                  "flat solid magenta (#FF00FF) around every character.")
        add(f"u{n:02d}", sheet, items, prompt, batch=2, bg=MAGENTA)

    # 4. Портреты 2×2: к запросу прикладывается готовый лист этих же персонажей
    for n, (ui, g) in enumerate(PORTRAIT_SHEETS, 1):
        ims = [bust("blank" if p == "zaraza" else "goblin" if p in ("shmyg", "mukhoglot") else "human") for p in g]
        sheet, rects = grid_sheet([im.convert("RGBA") for im in ims], 2, 24, WHITE)
        items = [{"id": f"portrait_{p}", "rect": r, "dir": "portraits", "mode": "square",
                  "art": {"id": f"portrait_{p}", "bind": f"portraits/{p}", "kind": "portrait", "painted": True,
                          "max_side": 264}} for p, r in zip(g, rects)]
        names = "; ".join(f"{k + 1} ({['top-left', 'top-right', 'bottom-left', 'bottom-right'][k]}): "
                          f"{portrait_text(p, prompts)}" for k, p in enumerate(g))
        prompt = (f"Image 1 shows {len(g)} dark square portrait frames with grey head-and-shoulders mannequins. Paint a "
                  f"dialogue portrait in every square as a {STYLE}. {STYLE_NOTE} Image 3 shows these same characters "
                  f"full body: keep their faces, hair, clothes and colours. Portraits: {names}. "
                  "Head and shoulders, three-quarter view facing right, eyes at the same height in every square, sharp "
                  "and detailed face, dark warm brown background with a soft vignette filling the whole square. "
                  "No text, no frame, no border.")
        add(f"p{n:02d}", sheet, items, prompt, attach_extra=[f"u{ui + 1:02d}.jpg"], batch=2)

    # 5. Значки 4×4: навыки, состояния, предметы
    icons = [("skills", k) for k in sprites["skills"]] + \
            [("skills", k) for k in ["crippling_blow", "rush", "battle_cry", "defensive_stance", "rage", "ground_slam",
                                      "pinning_shot", "fire_arrow", "hunters_mark", "arrow_rain", "tactical_retreat",
                                      "dirty_trick"] + list(NEW_SKILLS)] + \
            [("statuses", k) for k in sprites["statuses"]] + \
            [("statuses", k) for k in ["bleeding", "marked", "rallied", "fortified", "enraged"] + list(NEW_STATUSES)] + \
            [("items", k) for k in ["gold", "potion"] + list(ITEMS)]
    seen, uniq = set(), []
    for c, k in icons:
        if (c, k) not in seen:
            seen.add((c, k))
            uniq.append((c, k))
    tile = Image.new("RGBA", (128, 128), (200, 192, 180, 255))
    ImageDraw.Draw(tile).rectangle([0, 0, 127, 127], outline=(120, 110, 100, 255), width=3)
    for n, j in enumerate(range(0, len(uniq), 16), 1):
        part = uniq[j:j + 16]
        sheet, rects = grid_sheet([tile] * len(part), 4, 16, WHITE)
        items = []
        for (c, k), r in zip(part, rects):
            sid = {"skills": k, "statuses": k, "items": "item_" + k}[c]
            items.append({"id": sid, "rect": r, "dir": "icons", "mode": "square",
                          "art": {"id": sid, "bind": f"{c}/{k}", "kind": "icon", "painted": True, "max_side": 64}})
        names = "; ".join(f"{k + 1}) {icon_text(i, prompts)}" for k, (_, i) in enumerate(part))
        prompt = (f"Image 1 is a 4-column grid of {len(part)} empty squares. Paint one game icon inside every square, in "
                  f"order left to right, top to bottom, as a {STYLE}. {STYLE_NOTE} Icons: {names}. "
                  "Each icon fills its whole square edge to edge with a dark warm brown background and one large, clear, "
                  "centred subject readable at small size. Keep the squares exactly where they are, the white gaps "
                  "between them and the order. No text, no numbers, no frames.")
        add(f"i{n:02d}", sheet, items, prompt, batch=3)

    # 6. Вид с колокольни (как заставки intro_*), рамки и силуэт для интерфейса
    view = Image.new("RGB", (320, 180), WHITE)
    add("s01", view, [{"id": "image_bell_tower_view", "rect": [0, 0, 320, 180], "dir": "images", "mode": "full",
                       "art": {"id": "image_bell_tower_view", "bind": "images/bell_tower_view", "kind": "scene",
                               "painted": True, "max_side": 1280, "crop": False}}],
        f"Paint a wide 16:9 game cutscene picture as a {STYLE}. {STYLE_NOTE} View from the open belfry of a village "
        "bell tower at dusk, looking down over the village of Raven's Ford: tiled and thatched roofs, a small stone "
        "church, a river with a shallow ford and a path crossing it, the graveyard on a hill, dark forest beyond, "
        "crows in the sky. In the foreground on the worn wooden belfry floor next to the big bronze bell lies a single "
        "black rosary bead on a broken string. No people, no text. Fill the whole canvas.", batch=3)
    ui = Image.new("RGB", (420, 240), WHITE)
    d = ImageDraw.Draw(ui)
    d.rectangle([20, 20, 200, 200], fill=(150, 110, 70), outline=(60, 40, 24), width=3)
    d.rectangle([56, 56, 164, 164], fill=(226, 208, 170), outline=(60, 40, 24), width=3)
    for x, y in ((20, 20), (176, 20), (20, 176), (176, 176)):
        d.rectangle([x, y, x + 24, y + 24], fill=(190, 160, 80), outline=(60, 40, 24), width=2)
    d.rectangle([250, 60, 370, 180], fill=(60, 44, 30), outline=(150, 120, 70), width=6)
    add("s02", ui, [{"id": "image_ui_frame", "rect": [20, 20, 201, 201], "dir": "images", "mode": "square",
                     "art": {"id": "image_ui_frame", "bind": "images/ui_frame", "kind": "image", "painted": True,
                             "max_side": 96, "crop": False}},
                    {"id": "image_ui_slot", "rect": [250, 60, 371, 181], "dir": "images", "mode": "square",
                     "art": {"id": "image_ui_slot", "bind": "images/ui_slot", "kind": "image", "painted": True,
                             "max_side": 64, "crop": False}}],
        f"Image 1 shows two interface pieces for a game menu. Repaint them in the style of image 2: left, a square window "
        "frame of dark walnut wood planks with brass corner plates and small brass nails, with a parchment panel inside; "
        "right, an empty inventory slot: a square recess of dark carved wood with a thin brass rim. Keep both exactly "
        "where they are, keep their straight edges and square shapes, perfectly symmetric, seen straight on (not "
        "isometric). Plain flat white background, no text.", batch=3)
    doll = Image.new("RGB", (300, 420), (226, 208, 170))
    doll_im = Image.new("RGBA", (300, 420), (226, 208, 170, 255))
    fg = front_figure()
    doll_im.alpha_composite(fg, (42, 80))
    add("s03", doll_im.convert("RGB"), [{"id": "image_ui_paperdoll", "rect": [0, 0, 300, 420], "dir": "images",
                                          "mode": "full", "art": {"id": "image_ui_paperdoll", "bind": "images/ui_paperdoll",
                                                                  "kind": "image", "painted": True, "max_side": 420,
                                                                  "crop": False}}],
        "Image 1 is a rough layout for an RPG equipment screen. Repaint it as an old parchment page with a faint "
        "engraved outline of a standing human figure seen from the front (arms slightly away from the body), drawn in "
        "thin brown ink like an anatomical sketch, no face details, no clothes, no armour; the parchment fills the "
        "whole canvas with soft darker edges. " + STYLE_NOTE + " No text, no labels.", batch=3)

    # пергамент для окон рисует код сразу во входящие: бесшовность Gemini не держит
    dest = INBOX / "images"
    dest.mkdir(parents=True, exist_ok=True)
    parchment().save(dest / "image_ui_parchment.png")
    json.dump({"id": "image_ui_parchment", "bind": "images/ui_parchment", "kind": "image", "painted": True,
               "crop": False, "max_side": 256}, open(dest / "image_ui_parchment.art.json", "w", encoding="utf-8"))

    json.dump(jobs, open(JOBS / "jobs.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    json.dump(layout, open(JOBS / "layout.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    n_items = sum(len(v["items"]) for v in layout.values())
    print(f"листов: {len(jobs)}, картинок: {n_items} -> {JOBS}")


# --- Нарезка ответов ---------------------------------------------------------------------------------------------

def bg_mask(a: np.ndarray, bg) -> np.ndarray:
    """Фон, связанный с краем куска: белый — светлый и почти серый, пурпурный — близко к #FF00FF."""
    from scipy import ndimage
    a = a.astype(np.int16)
    if tuple(bg) == MAGENTA:
        r, g, b = a[..., 0], a[..., 1], a[..., 2]
        cand = (r > 150) & (b > 150) & (g < 120) & (np.abs(r - b) < 90)
    else:
        cand = (a.min(axis=2) > 228) & ((a.max(axis=2) - a.min(axis=2)) < 24)
    lab, _ = ndimage.label(cand)
    edge = set(np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))) - {0}
    bgm = np.isin(lab, list(edge))
    if tuple(bg) == MAGENTA:
        bgm |= cand                     # пурпур между ногами и в просветах — тоже фон
    return bgm


def cutout(piece: Image.Image, bg) -> Image.Image:
    from scipy import ndimage
    a = np.asarray(piece.convert("RGB"))
    fg = ~bg_mask(a, bg)
    fg = ndimage.binary_opening(fg, iterations=2)
    lab, n = ndimage.label(fg)
    if n:
        sizes = ndimage.sum(fg, lab, range(1, n + 1))
        keep = [i + 1 for i in range(n) if sizes[i] >= 0.04 * sizes.max()]
        fg = np.isin(lab, keep)
    fg = ndimage.binary_erosion(fg, iterations=1)
    rgb = a.copy()
    if tuple(bg) == MAGENTA:                                          # пурпурная кайма на краях -> тёмная обводка
        edge = fg & ~ndimage.binary_erosion(fg, iterations=2)
        pink = (rgb[..., 0].astype(int) > 140) & (rgb[..., 2].astype(int) > 140) & (rgb[..., 1].astype(int) < 140)
        rgb[edge & pink] = (40, 30, 26)
    return Image.fromarray(np.dstack([rgb, (fg * 255).astype(np.uint8)]), "RGBA")


def cut(only: list[str] | None = None) -> None:
    layout = json.load(open(JOBS / "layout.json", encoding="utf-8"))
    report = []
    for job, info in layout.items():
        if only and job not in only:
            continue
        src = next((p for p in (OUT / f"{job}.jpg", OUT / f"{job}.png", OUT / f"{job}.jpeg") if p.exists()), None)
        if src is None:
            continue
        out = Image.open(src).convert("RGB")
        bw, bh = info["base"]
        sx, sy = out.width / bw, out.height / bh
        if abs(sx / sy - 1) > 0.04:
            report.append(f"{job}: пропорции листа изменились ({sx:.2f} × {sy:.2f}), режу по каждой оси отдельно")
        for it in info["items"]:
            x0, y0, x1, y1 = it["rect"]
            pad = 0.0 if it["mode"] in ("house", "unit", "full") else 0.02
            if it["mode"] == "square":
                inset = round((x1 - x0) * 0.025)
                x0, y0, x1, y1 = x0 + inset, y0 + inset, x1 - inset, y1 - inset
            box = (round(x0 * sx), round(y0 * sy), round(x1 * sx), round(y1 * sy))
            piece = out.crop(box)
            if it["mode"] in ("house", "unit", "cut"):
                piece = cutout(piece, info["bg"])
                if it["mode"] == "house":
                    piece = match_house(piece, it)
            dest = INBOX / it["dir"]
            dest.mkdir(parents=True, exist_ok=True)
            piece.save(dest / f"{it['id']}.png")
            json.dump(it["art"], open(dest / f"{it['id']}.art.json", "w", encoding="utf-8"), ensure_ascii=False)
        report.append(f"{job}: {len(info['items'])} шт.")
    print("\n".join(report))


def match_house(piece: Image.Image, it: dict) -> Image.Image:
    """Дом из Gemini против дома из кода: совпадение силуэта (если сильно разошлось — предупреждение)."""
    ref = Image.open(ROOT / "art/inbox/buildings" / f"{it['id']}.png").convert("RGBA")
    small = piece.resize(ref.size, Image.BOX)
    a = np.asarray(small)[..., 3] > 127
    b = np.asarray(ref)[..., 3] > 0
    iou = float((a & b).sum() / max(1, (a | b).sum()))
    if iou < 0.95:
        print(f"  ! {it['id']}: силуэт совпал только на {iou:.0%}")
    return piece


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sheets")
    s.add_argument("--style", default=str(ROOT / "art/nano/style.jpg"), help="образец стиля для Gemini")
    c = sub.add_parser("cut")
    c.add_argument("jobs", nargs="*")
    a = ap.parse_args()
    if a.cmd == "sheets":
        build_sheets(Path(a.style))
    else:
        cut(a.jobs or None)


if __name__ == "__main__":
    main()
