"""Вороний Брод, раунд 4: просторная деревня без сетки. Река Ворожея петляет с севера на юг, тракт с погоста
идёт через мощёную площадь к деревянному мосту и дальше в лес; южнее через реку — брод по камням к мельнику.
Дома стоят группами, вокруг огороды, сады, загон для овец; от каждой двери к тракту ведёт тропинка.
Размеры домов, их двери (сторона и смещение) и обстановка — те же, что раньше: рисунки домов к ним подогнаны."""
import heapq
import math
import random
from canvas import Canvas, check
from village import INTERIORS, F, POOL, door_cell

W, H = 100, 74

# дома: (id, x, y, w, h, дверь "s" | "e", смещение двери, имя, материал, обстановка, сундук) — порядок как раньше
HOUSES = [
    ("headman", 19, 26, 8, 7, "s", 4, "Дом старосты Яцека", "timber", "headman", "chest_headman"),
    ("cooper", 3, 23, 6, 6, "e", 3, "Дом бондаря", "timber", "cooper", None),
    ("weaver", 17, 44, 5, 5, "s", 2, "Дом ткачихи Ганны", "timber", "weaver", None),
    ("korn", 51, 13, 7, 6, "s", 3, "Дом Корнов", "timber", "family", "chest_korn"),
    ("fisher", 79, 23, 8, 5, "s", 2, "Дом рыбака Савки", "timber", "fisher", "chest_fisher"),
    ("shepherd", 3, 43, 7, 6, "e", 3, "Дом пастуха", "log", "shepherd", None),
    ("carpenter", 26, 47, 6, 6, "s", 3, "Дом плотника", "timber", "carpenter", None),
    ("widow", 3, 12, 5, 5, "s", 2, "Дом вдовы Агаты", "timber", "widow", None),
    ("beekeeper", 5, 62, 5, 6, "e", 2, "Дом пасечника", "log", "beekeeper", None),
    ("chandler", 60, 5, 6, 6, "s", 2, "Дом свечника", "timber", "chandler", None),
    ("miller", 82, 57, 7, 6, "s", 3, "Дом мельника", "timber", "miller", None),
    ("potter", 30, 61, 6, 5, "s", 3, "Дом гончара", "timber", "potter", "chest_potter"),
    ("shoemaker", 36, 48, 5, 5, "s", 2, "Дом сапожника", "timber", "shoemaker", None),
    ("midwife", 11, 27, 5, 6, "e", 3, "Дом повитухи Божены", "log", "midwife", None),
    ("boatman", 78, 44, 7, 5, "s", 3, "Дом лодочника", "timber", "boatman", None),
    ("hunter", 91, 9, 6, 5, "s", 2, "Дом охотника", "log", "hunter", None),
    ("healer", 42, 62, 6, 6, "e", 3, "Дом знахаря", "log", "healer", None),
    ("tanner", 59, 59, 5, 5, "s", 2, "Дом кожевника", "timber", "tanner", None),
    ("brzezinski", 47, 47, 5, 8, "e", 3, "Дом семьи Бжезинских", "timber", "big_family", "chest_family"),
    ("baker", 51, 37, 7, 6, "s", 3, "Дом пекаря", "timber", "baker", "chest_baker"),
]
BARNS = [
    ("barn", 15, 56, 9, 7, "s", 4, "Амбар", "barn", "chest_barn"),
    ("shed", 90, 45, 6, 6, "s", 3, "Сарай", "shed", None),
]

# жители: (id, где хочется поставить) — ставятся на ближайшую свободную клетку
VILLAGERS = [
    ("jacek", 25, 35), ("hanna", 20, 50), ("savka", 76, 30), ("agata", 7, 19), ("yurek", 47, 36),
    ("bolek", 55, 22), ("zbyszek", 43, 31), ("matey", 12, 38), ("tomash", 54, 46), ("vlasta", 21, 65),
    ("bozhena", 17, 34), ("stefan", 61, 33),
]

LEGEND = {}
LETTERS = {}


def letter(key):
    if key not in LETTERS:
        used = set(LETTERS.values()) | set(LEGEND.keys()) | set(F.keys()) | set("#. =_+`")
        LETTERS[key] = next(ch for ch in POOL if ch not in used)
    return LETTERS[key]


def river_x(y):
    """середина русла Ворожеи в строке y"""
    return 71.0 + 4.0 * math.sin(y / 7.0 + 0.9) + 1.0 * math.sin(y / 2.9)


def road_y(x):
    """середина тракта в столбце x"""
    return 36.5 + 2.4 * math.sin(x / 12.5 - 0.6)


def furnish(c, x, y, w, h, door, kind, chest_letter):
    dx, dy = door
    near_door = {(dx + a, dy + b) for a in (-1, 0, 1) for b in (-1, 0, 1)}
    x0, y0 = x + 1, y + 1
    iw, ih = w - 2, h - 2
    for (rx, ry, ch) in INTERIORS[kind]:
        cx = x0 + (rx if rx >= 0 else iw + rx)
        cy = y0 + (ry if ry >= 0 else ih + ry)
        if not (x0 <= cx < x0 + iw and y0 <= cy < y0 + ih) or (cx, cy) in near_door:
            continue
        if ch == "chest":
            if not chest_letter:
                continue
            ch = chest_letter
        if c.get(cx, cy) == "_":
            c.put(cx, cy, ch)


class Village:
    def __init__(self):
        self.c = Canvas(W, H, "#", seed=41)
        self.rng = random.Random(57)
        self.deco = {}        # (x, y) -> path | square | field | bridge_x | stones
        self.rects = []       # занятые прямоугольники (дома с кольцом вокруг), чтобы ничего не налезло
        self.water = set()
        self.waves = [(self.rng.uniform(0.15, 0.45), self.rng.uniform(-0.45, 0.45), self.rng.uniform(0, 6.3), 0.6)
                      for _ in range(4)]

    # --- помощники -----------------------------------------------------------------------
    def free(self, x, y):
        return 0 < x < W - 1 and 0 < y < H - 1 and self.c.get(x, y) == "."

    def reserve(self, x, y, w, h, pad=1):
        r = (x - pad, y - pad, x + w - 1 + pad, y + h - 1 + pad)
        for o in self.rects:
            if not (r[2] < o[0] or o[2] < r[0] or r[3] < o[1] or o[3] < r[1]):
                raise AssertionError(f"налезает: {r} и {o}")
        self.rects.append(r)

    def house(self, x, y, w, h, corner, doors):
        self.reserve(x, y, w, h)
        for (xx, yy) in [(xx, yy) for yy in range(y, y + h) for xx in range(x, x + w)]:
            assert (xx, yy) not in self.water, ("дом в реке", corner, xx, yy)
        self.c.building(x, y, w, h, corner, doors)

    def mark(self, x, y, kind, force=False):
        if 0 < x < W - 1 and 0 < y < H - 1 and (force or self.c.get(x, y) == "."):
            self.deco[(x, y)] = kind
            self.c.keep.add((x, y))

    def blocked(self, x, y):
        ch = self.c.get(x, y)
        return ch not in ".`" and not (ch in "~" and (x, y) in self.deco)

    # --- части деревни ---------------------------------------------------------------------
    def river(self):
        c = self.c
        self.ford_rows = range(60, 63)
        for y in range(1, H - 1):
            m = river_x(y)
            x0, x1 = int(round(m - 2)), int(round(m + 2))
            for x in range(x0, x1):
                self.water.add((x, y))
                c.put(x, y, "~" if y in self.ford_rows else "v")
            for bank in (x0 - 1, x1):
                if y in self.ford_rows:
                    continue
                r = self.rng.random()
                if r < 0.4:
                    c.put(bank, y, "j")      # камыш
                elif r < 0.48:
                    c.put(bank, y, "o")      # камень у воды
        # брод: камни поперёк реки, по ним тропа к мельнику
        for x in range(1, W - 1):
            if (x, 61) in self.water:
                self.deco[(x, 61)] = "stones"

    def road(self):
        """тракт: с погоста (запад) через площадь к мосту и в лес (восток), ширина 3"""
        self.road_cells = set()
        for x in range(1, W - 1):
            m = road_y(x)
            for y in range(int(round(m)) - 1, int(round(m)) + 2):
                self.road_cells.add((x, y))
                if (x, y) in self.water:
                    self.c.put(x, y, ".")
                    self.deco[(x, y)] = "bridge_x"
                    self.c.keep.add((x, y))
                elif self.c.get(x, y) in "jo":
                    self.c.put(x, y, ".")
                    self.mark(x, y, "path")
                else:
                    self.mark(x, y, "path")
        # перила моста продолжаются на берег на клетку
        self.ends = (int(round(road_y(0))), int(round(road_y(W - 1))))

    def square(self):
        """мощёная площадь со срезанными углами: колодец, доска, путевой камень, лоток Збышека"""
        c = self.c
        x0, y0, x1, y1 = 33, 30, 49, 44
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                cut = min(x - x0, x1 - x, y - y0, y1 - y)
                corner = min(x - x0, x1 - x) + min(y - y0, y1 - y)
                if corner < 3:
                    continue
                self.mark(x, y, "square", force=(x, y) in self.road_cells)
        c.footprint(40, 36, 2, 2, "W")
        self.reserve(40, 36, 2, 2, pad=0)
        c.put(36, 32, "n")
        c.put(45, 41, "@")
        # лоток: прилавок и ящики, торговец за прилавком
        for x in (42, 43, 44):
            c.put(x, 32, "Q")
        c.put(41, 31, "X"); c.put(45, 31, "U")
        for x in range(40, 47):
            c.keep.add((x, 33))

    def church(self):
        c = self.c
        cx, cy = 10, 6   # церковь 11×8, дверь снизу со смещением 5 (как в рисунке)
        self.house(cx, cy, 11, 8, "C", [(cx + 5, cy + 7)])
        c.put(cx + 5, cy + 1, "Z"); c.put(cx + 5, cy + 2, "P"); c.put(cx + 4, cy + 2, "c")
        for yy in (3, 4, 5):
            for xx in (2, 3, 7, 8):
                c.put(cx + xx, cy + yy, "p")
        c.put(cx + 1, cy + 1, "I"); c.put(cx + 9, cy + 1, "I")
        # колокольня справа от церкви, дорожка к ней
        c.footprint(cx + 13, cy + 4, 2, 2, "5")
        self.reserve(cx + 13, cy + 4, 2, 2, pad=0)
        # погостик при церкви: надгробия к югу и западу
        for p in [(9, 16), (11, 17), (13, 16), (18, 17), (20, 16), (9, 19), (12, 20), (19, 20), (21, 19), (7, 17)]:
            if self.free(*p):
                c.put(*p, "%")
        # дом священника 7×5, дверь снизу со смещением 3
        px, py = 26, 2
        self.house(px, py, 7, 5, "E", [(px + 3, py + 4)])
        c.put(px + 4, py + 1, "k"); c.put(px + 1, py + 1, "D"); c.put(px + 5, py + 1, "I"); c.put(px + 1, py + 2, "U")

    def tavern(self):
        c = self.c
        tx, ty = 33, 17   # 16×11; двери: снизу смещение 7, справа смещение 5
        self.house(tx, ty, 16, 11, "R", [(tx + 7, ty + 10), (tx + 15, ty + 5)])
        dx, dy = tx - 36, ty - 7   # обстановка — как в прежней таверне, со сдвигом
        for (xx, yy, ch) in [(37, 8, "U"), (38, 8, "U"), (39, 8, "I"), (40, 8, "I"), (41, 8, "U"), (44, 8, "V"), (45, 8, "V"),
                             (48, 8, "I"), (49, 8, "U"), (50, 8, "U"), (37, 9, "X"), (37, 10, "U")]:
            c.put(xx + dx, yy + dy, ch)
        for xx in (38, 39, 40, 41, 42):
            c.put(xx + dx, 11 + dy, "Q")
        c.put(40 + dx, 10 + dy, "M")
        for (xx, yy) in [(45, 11), (45, 14), (48, 14), (39, 14)]:
            c.put(xx + dx, yy + dy, "Y"); c.put(xx + 1 + dx, yy + dy, "J"); c.put(xx - 1 + dx, yy + dy, "J")
        c.put(48 + dx, 11 + dy, "Y"); c.put(48 + dx, 10 + dy, "J")
        c.put(37 + dx, 16 + dy, "U"); c.put(50 + dx, 16 + dy, "X"); c.put(37 + dx, 15 + dy, "U")
        c.put(43 + dx, 12 + dy, "K"); c.put(47 + dx, 12 + dy, "r")

    def smithy(self):
        c = self.c
        sx, sy = 55, 25   # 9×7, дверь снизу со смещением 4
        self.house(sx, sy, 9, 7, "F", [(sx + 4, sy + 6)])
        dx, dy = sx - 55, sy - 33
        for (xx, yy, ch) in [(58, 34, "V"), (59, 34, "V"), (57, 36, "a"), (56, 36, "u"), (60, 36, "A"), (56, 34, "U"),
                             (62, 34, "X"), (62, 37, "U"), (62, 36, "X"), (56, 38, "I")]:
            c.put(xx + dx, yy + dy, ch)
        # дрова и бочка с водой у кузни
        c.put(sx + 9, sy + 5, "U"); c.put(sx - 1, sy + 2, "X")

    def homes(self):
        for (hid, x, y, w, h, side, off, name, mat, kind, chest) in HOUSES:
            d = door_cell(x, y, w, h, side, off)
            self.house(x, y, w, h, letter(hid), [d])
            furnish(self.c, x, y, w, h, d, kind, letter(chest) if chest else None)
        for (hid, x, y, w, h, side, off, name, kind, chest) in BARNS:
            d = door_cell(x, y, w, h, side, off)
            self.house(x, y, w, h, letter(hid), [d])
            furnish(self.c, x, y, w, h, d, kind, letter(chest) if chest else None)

    def gardens(self):
        """огороды (грядки за плетнём), загон для овец, сад, пасека, стог у амбара"""
        c = self.c
        beds = [(10, 15, 5, 3), (3, 31, 5, 4), (29, 40, 5, 3), (60, 14, 5, 3), (88, 25, 5, 3), (44, 56, 5, 4),
                (37, 55, 4, 3), (93, 61, 4, 4), (6, 69, 5, 3), (65, 47, 4, 3)]
        for (x, y, w, h) in beds:
            for yy in range(y, y + h):
                for xx in range(x, x + w):
                    if self.free(xx, yy) and (xx, yy) not in self.road_cells:
                        self.deco[(xx, yy)] = "field"
                        c.keep.add((xx, yy))
            # капуста и кусты на грядках
            for _ in range(w * h // 4):
                xx, yy = x + self.rng.randrange(w), y + self.rng.randrange(h)
                if self.deco.get((xx, yy)) == "field" and c.get(xx, yy) == ".":
                    c.put(xx, yy, ",")
        # загон для овец у пастуха: плетень с калиткой, внутри стог
        px, py, pw, ph = 3, 51, 9, 7
        for xx in range(px, px + pw):
            for yy in (py, py + ph - 1):
                if self.free(xx, yy):
                    c.put(xx, yy, "#")
        for yy in range(py, py + ph):
            for xx in (px, px + pw - 1):
                if self.free(xx, yy):
                    c.put(xx, yy, "#")
        c.put(px + pw - 1, py + 3, ".")   # калитка
        c.keep.add((px + pw, py + 3))
        c.put(px + 2, py + 2, "<"); c.put(px + 5, py + 4, "<")
        # стога и ящики у амбара и сарая
        for p in [(25, 58), (25, 60), (13, 60), (97, 47), (89, 51)]:
            if self.free(*p):
                c.put(*p, "<")
        # бочки и ящики у домов на улице
        for p in [(28, 31), (9, 25), (59, 19), (87, 26), (85, 47), (35, 52), (58, 41), (64, 61), (49, 54)]:
            if self.free(*p):
                c.put(*p, self.rng.choice("UX"))

    def pond(self):
        """пруд за таверной: глубокая вода, камыш по берегу"""
        cx, cy = 39.5, 9.0
        for y in range(5, 14):
            for x in range(33, 47):
                d = ((x - cx) / 4.6) ** 2 + ((y - cy) / 2.6) ** 2
                if d < 1.0:
                    self.c.put(x, y, "v")
                    self.water.add((x, y))
                elif d < 1.5 and self.free(x, y) and self.rng.random() < 0.55:
                    self.c.put(x, y, "j" if self.rng.random() < 0.8 else "o")

    def place_specials(self):
        c = self.c
        # выходы и точки появления
        wy, ey = self.ends
        for y in (wy - 1, wy, wy + 1):
            c.put(0, y, "1")
        for y in (ey - 1, ey, ey + 1):
            c.put(W - 1, y, "2")
        for p in [(2, wy), (2, wy + 1), (3, wy), (3, wy + 1)]:
            c.put(*p, "b")
        for p in [(W - 3, ey), (W - 3, ey - 1), (W - 4, ey), (W - 4, ey - 1)]:
            c.put(*p, "f")
        for p in [(37, 38), (38, 38), (37, 39), (38, 39)]:
            c.put(*p, "s")
        c.put(5, wy - 3, "G")
        self.c.keep.add((5, wy - 3))

    def paths(self):
        """тропинки от каждой двери (и к колокольне, калитке, броду) до тракта: Дейкстра, по готовым тропам дешевле"""
        targets = set(self.road_cells) | {p for p, k in self.deco.items() if k == "square"}
        starts = []
        for (x, y) in [(x, y) for y in range(H) for x in range(W) if self.c.get(x, y) == "+"]:
            for nx, ny in ((x, y + 1), (x + 1, y)):
                if 0 < nx < W - 1 and 0 < ny < H - 1 and self.c.get(nx, ny) in ".`" and not self._inside(nx, ny):
                    starts.append((nx, ny))
        starts += [(25, 11), (12, 54), (69, 61), (76, 61)]
        # сначала ближние к тракту: дальние тропы потом вливаются в них, получается ветвистая сеть, а не гребёнка
        for s in sorted(starts, key=lambda p: abs(p[1] - road_y(p[0])) + 0.3 * abs(p[0] - 41)):
            self._route(s, targets)

    def wobble(self, x, y):
        """плавный шум: тропы огибают «бугры» и петляют, а не идут по линейке"""
        v = 0.0
        for (fx, fy, ph, a) in self.waves:
            v += a * math.sin(x * fx + y * fy + ph)
        return v

    def _inside(self, x, y):
        """клетка внутри какого-нибудь дома (по кольцу стен)"""
        for (x0, y0, x1, y1) in self.rects:
            if x0 + 1 < x < x1 - 1 and y0 + 1 < y < y1 - 1:
                return True
        return False

    def _route(self, start, targets):
        dist = {start: 0.0}
        prev = {}
        pq = [(0.0, start)]
        goal = None
        while pq:
            d, (x, y) = heapq.heappop(pq)
            if d > dist[(x, y)]:
                continue
            if (x, y) in targets or self.deco.get((x, y)) == "path" and (x, y) != start:
                goal = (x, y)
                break
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                n = (x + dx, y + dy)
                if not (0 < n[0] < W - 1 and 0 < n[1] < H - 1):
                    continue
                ch = self.c.get(*n)
                k = self.deco.get(n)
                if k in ("bridge_x", "stones"):
                    cost = 1.0
                elif ch not in ".," or self._inside(*n) or k == "field":
                    continue
                else:
                    cost = 0.35 if k == "path" else 1.0 + 0.55 * (self.wobble(*n) + 2.4) + (0.6 if ch == "," else 0.0)
                nd = d + cost
                if nd < dist.get(n, 1e9):
                    dist[n] = nd
                    prev[n] = (x, y)
                    heapq.heappush(pq, (nd, n))
        if goal is None:
            print("WARN нет тропы от", start); return
        p = goal
        while p != start:
            p = prev[p]
            if self.deco.get(p) not in ("bridge_x", "stones", "square"):
                if self.c.get(*p) == ",":
                    self.c.put(*p, ".")
                self.mark(*p, "path")
        self.mark(*start, "path")

    def villagers(self):
        c = self.c
        for (nid, x, y) in VILLAGERS:
            best = None
            for r in range(0, 6):
                for yy in range(y - r, y + r + 1):
                    for xx in range(x - r, x + r + 1):
                        if best is None and self.free(xx, yy) and (xx, yy) not in self.road_cells \
                                and self.deco.get((xx, yy)) not in ("field",) and not self._inside(xx, yy):
                            best = (xx, yy)
                if best:
                    break
            assert best, nid
            c.put(*best, letter("npc_" + nid))
            if nid == "zbyszek":
                assert best[1] <= 31, best   # за прилавком

    def nature(self):
        """сады и рощи кучками, кусты, камни; тропы, дворы и берег у брода не трогаем"""
        c = self.c
        groves = [(44, 6, 7), (70, 8, 0), (84, 15, 6), (95, 28, 6), (66, 21, 0), (3, 3, 5), (36, 10, 4),
                  (24, 70, 6), (52, 68, 7), (64, 68, 5), (96, 68, 6), (74, 52, 0), (92, 37, 0), (3, 37, 0),
                  (28, 20, 4), (60, 50, 4), (88, 3, 5), (14, 71, 4), (38, 70, 5), (46, 23, 0)]
        for (gx, gy, n) in groves:
            n = n or 4
            n = n * 2
            for _ in range(n * 3):
                if n <= 0:
                    break
                x = int(round(gx + self.rng.gauss(0, 1.9)))
                y = int(round(gy + self.rng.gauss(0, 1.6)))
                if 0 < x < W - 1 and 0 < y < H - 1 and self.free(x, y) and (x, y) not in c.keep \
                        and (x, y) not in self.deco:
                    c.put(x, y, "T", keep=False)
                    n -= 1
        # опушка: по краю карты лес гуще, деревня как на поляне
        for y in range(1, H - 1):
            for x in range(1, W - 1):
                edge = min(x, y, W - 1 - x, H - 1 - y)
                if edge <= 4 and self.free(x, y) and (x, y) not in c.keep and (x, y) not in self.deco \
                        and self.rng.random() < (0.5 if edge <= 2 else 0.22):
                    c.put(x, y, "T", keep=False)
        c.scatter("T", 30, 1, 1, W - 2, H - 2)
        c.scatter(",", 70, 1, 1, W - 2, H - 2)
        c.scatter("o", 14, 1, 1, W - 2, H - 2)
        for (x, y), k in self.deco.items():   # на тропах ничего не растёт
            assert k not in ("path", "bridge_x", "stones") or c.get(x, y) not in "T,o<UX#", (x, y, k, c.get(x, y))

    def build(self):
        self.river()
        self.road()
        self.square()
        self.church()
        self.tavern()
        self.smithy()
        self.pond()
        self.homes()
        self.place_specials()
        self.gardens()
        self.villagers()
        self.paths()
        self.nature()
        rows = self.c.rows()
        # клетки с рисунком на земле получают свои буквы (тропа, мостовая, грядки, мост, брод)
        sym = {"path": "`", "square": "'", "field": "\"", "bridge_x": "|", "stones": "°"}
        out = [list(r) for r in rows]
        for (x, y), k in self.deco.items():
            ch = out[y][x]
            if ch == "." or (k == "stones" and ch == "~"):
                out[y][x] = sym[k]
        return ["".join(r) for r in out]


LEGEND.update({
    "T": {"prop": "tree"}, ",": {"prop": "bush", "block": False}, "j": {"prop": "reeds", "block": False},
    "o": {"prop": "rock"},
    "~": {"surface": "water"}, "v": {"surface": "water", "solid": True}, "h": {"solid": True},
    "`": {"deco": "path"}, "'": {"deco": "square"}, "\"": {"deco": "field"}, "|": {"deco": "bridge_x"},
    "°": {"deco": "stones", "surface": "water"},
    "%": {"prop": "tombstone"},
    "C": {"building": "church", "size": [11, 8], "name": "Церковь Тихого Берега", "material": "stone", "roof": "slate",
          "cross": True, "sprite": "bld_church"},
    "E": {"building": "priest_house", "size": [7, 5], "name": "Дом священника", "material": "timber", "roof": "thatch",
          "sprite": "bld_priest_house"},
    "R": {"building": "tavern", "size": [16, 11], "name": "Таверна «Пьяный Ворон»", "material": "timber", "roof": "shingle",
          "chimney": True, "sprite": "bld_tavern", "music": "tavern"},
    "F": {"building": "smithy", "size": [9, 7], "name": "Кузня Гюнтера", "material": "stone", "roof": "slate",
          "chimney": True, "sprite": "bld_smithy"},
    "5": {"object": "bell_tower", "size": [2, 2]},
    "k": {"object": "tadeush_table"}, "n": {"object": "notice_board"}, "W": {"prop": "well", "size": [2, 2]},
    "@": {"object": "waystone_village", "waypoint": True, "name": "Площадь Вороньего Брода"},
    "Z": {"prop": "altar"}, "p": {"prop": "pew"},
    "P": {"npc": "tadeush"}, "M": {"npc": "marta"}, "r": {"npc": "pipin"}, "u": {"npc": "gunter"},
    "c": {"anchor": "church"}, "K": {"anchor": "tavern"}, "G": {"anchor": "cemetery_gate"}, "A": {"anchor": "smithy"},
    "b": {"spawn": "from_cemetery"}, "1": {"exit": "to_cemetery"}, "f": {"spawn": "from_forest"}, "2": {"exit": "to_forest"},
    "s": {"spawn": "start"},
})
for ch, prop in F.items():
    LEGEND[ch] = {"prop": prop}
for (hid, x, y, w, h, side, off, name, mat, kind, chest) in HOUSES:
    LEGEND[letter(hid)] = {"building": "house_" + hid, "size": [w, h], "name": name, "material": mat,
                           "roof": "thatch" if mat == "log" else "shingle", "sprite": "bld_house_" + hid}
for (hid, x, y, w, h, side, off, name, kind, chest) in BARNS:
    LEGEND[letter(hid)] = {"building": hid, "size": [w, h], "name": name, "material": "log", "roof": "thatch",
                           "sprite": "bld_" + hid}
for chest in sorted({hc[-1] for hc in HOUSES + BARNS if hc[-1]}):
    LEGEND[letter(chest)] = {"object": chest, "look": "chest"}
for (nid, x, y) in VILLAGERS:
    LEGEND[letter("npc_" + nid)] = {"npc": nid}


def build():
    return Village().build()


if __name__ == "__main__":
    rows = build()
    print("\n".join(rows))
    print(check("village", rows, LEGEND, (3, int(round(road_y(3))))))
