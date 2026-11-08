"""Вороний Брод: два десятка домов разного размера, большая таверна, кузня, церковь с колокольней, речка Ворожея с бродом.
Все дома — настоящие: стены, дверь на видимой стороне (нижний ряд или правый столбец), своя обстановка внутри.
По улицам ходят жители (NPC с репликами)."""
import math
import random
from canvas import Canvas, check

W, H = 84, 60
RIVER = range(66, 71)        # Ворожея: столбцы глубокой воды
FORD = range(29, 33)         # брод: мелкая вода, можно перейти

# мебель: буква легенды -> предмет
F = {"D": "bed", "V": "hearth", "I": "shelf", "U": "barrel", "X": "crate", "Y": "table", "J": "bench", "Q": "counter",
     "a": "anvil", "*": "sacks", "<": "hay", ">": "workbench", "?": "pots", ";": "loom", ":": "cauldron", "[": "rack",
     "]": "oven", "{": "herbs"}

# обстановка по виду дома: (x, y, буква) от дальнего левого угла комнаты; отрицательные — от правого/ближнего края.
# Средний ряд и клетки у двери остаются свободными, поэтому до всего можно дойти.
INTERIORS = {
    "headman":   [(0, 0, "D"), (1, 0, "D"), (3, 0, "V"), (5, 0, "I"), (-1, 1, "chest"), (0, 2, "I"), (0, 3, "U"),
                  (3, 2, "Y"), (2, 2, "J"), (4, 2, "J"), (-1, -1, "U")],
    "cooper":    [(0, 0, "D"), (2, 0, "V"), (-1, 0, "U"), (0, 2, "U"), (0, -1, "U"), (2, 2, ">"), (-1, -1, "U"), (-1, 2, "U")],
    "weaver":    [(0, 0, "D"), (2, 0, ";"), (-1, 0, "I"), (0, -1, "*"), (-1, -1, "V")],
    "family":    [(0, 0, "D"), (1, 0, "D"), (3, 0, "V"), (-1, 0, "chest"), (0, 2, "D"), (3, 2, "Y"), (4, 2, "J"), (-1, -1, "X")],
    "fisher":    [(0, 0, "D"), (2, 0, "V"), (4, 0, "["), (-1, 0, "chest"), (0, 2, "U"), (-1, 2, "U"), (3, 2, "X")],
    "shepherd":  [(0, 0, "D"), (2, 0, "V"), (-1, 0, "<"), (-1, 1, "<"), (0, -1, "X"), (2, 2, "Y"), (3, 2, "J")],
    "carpenter": [(0, 0, "D"), (2, 0, "V"), (-1, 0, "X"), (0, 2, ">"), (0, 3, "X"), (-1, 2, "X"), (-1, -1, "I")],
    "widow":     [(0, 0, "D"), (2, 0, "V"), (0, -1, "I"), (-1, -1, "Y")],
    "beekeeper": [(0, 0, "D"), (2, 0, "V"), (0, 2, "I"), (0, -1, "U"), (-1, 0, "U"), (2, -1, "Y")],
    "chandler":  [(0, 0, "D"), (2, 0, "V"), (-1, 0, "I"), (0, 2, "I"), (0, -1, "X"), (3, 2, "Y")],
    "miller":    [(0, 0, "D"), (2, 0, "V"), (4, 0, "*"), (-1, 0, "*"), (-1, 1, "*"), (0, 2, "U"), (0, 3, "*"), (3, 2, "Y")],
    "potter":    [(0, 0, "D"), (2, 0, "]"), (-1, 0, "chest"), (0, 2, "?"), (-1, 2, "?"), (2, 2, ">")],
    "shoemaker": [(0, 0, "D"), (2, 0, "V"), (0, -1, ">"), (-1, -1, "I")],
    "midwife":   [(0, 0, "D"), (2, 0, "V"), (0, 2, "{"), (-1, 0, "I"), (0, -1, ":")],
    "boatman":   [(0, 0, "D"), (2, 0, "V"), (4, 0, "["), (-1, 0, "U"), (0, -1, "X"), (-1, -1, "U")],
    "hunter":    [(0, 0, "D"), (2, 0, "V"), (-1, 0, "["), (0, -1, "["), (3, 2, "Y")],
    "healer":    [(0, 0, "D"), (2, 0, ":"), (-1, 0, "{"), (0, 2, "I"), (0, -1, "{"), (-1, -1, "I")],
    "tanner":    [(0, 0, "D"), (2, 0, "["), (0, -1, "U"), (-1, -1, "U")],
    "big_family": [(0, 0, "D"), (1, 0, "D"), (-1, 0, "D"), (2, 0, "V"), (0, 2, "chest"), (2, 3, "Y"), (2, 2, "J"), (-1, -1, "X")],
    "baker":     [(0, 0, "D"), (1, 0, "chest"), (2, 0, "]"), (3, 0, "]"), (-1, 0, "*"), (0, 2, "*"), (3, 2, "Y"), (4, 2, "J"), (-1, -1, "U")],
    "barn":      [(0, 0, "<"), (1, 0, "<"), (-1, 0, "<"), (0, 1, "*"), (0, -1, "X"), (-2, 0, "U"), (-1, 1, "chest")],
    "shed":      [(0, 0, "X"), (1, 0, "U"), (-1, 0, "<"), (0, 1, "X")],
}

# дома: (id, x, y, w, h, дверь "s" (нижний ряд) | "e" (правый столбец), смещение двери, имя, материал, обстановка, сундук)
HOUSES = [
    ("headman", 3, 2, 8, 7, "s", 4, "Дом старосты Яцека", "timber", "headman", "chest_headman"),
    ("cooper", 3, 11, 6, 6, "e", 3, "Дом бондаря", "timber", "cooper", None),
    ("weaver", 27, 11, 5, 5, "s", 2, "Дом ткачихи Ганны", "timber", "weaver", None),
    ("korn", 55, 2, 7, 6, "s", 3, "Дом Корнов", "timber", "family", "chest_korn"),
    ("fisher", 55, 10, 8, 5, "s", 2, "Дом рыбака Савки", "timber", "fisher", "chest_fisher"),
    ("shepherd", 3, 21, 7, 6, "e", 3, "Дом пастуха", "log", "shepherd", None),
    ("carpenter", 14, 21, 6, 6, "s", 3, "Дом плотника", "timber", "carpenter", None),
    ("widow", 22, 21, 5, 5, "s", 2, "Дом вдовы Агаты", "timber", "widow", None),
    ("beekeeper", 28, 21, 5, 6, "e", 2, "Дом пасечника", "log", "beekeeper", None),
    ("chandler", 55, 21, 6, 6, "s", 2, "Дом свечника", "timber", "chandler", None),
    ("miller", 3, 34, 7, 6, "s", 3, "Дом мельника", "timber", "miller", None),
    ("potter", 13, 34, 6, 5, "s", 3, "Дом гончара", "timber", "potter", "chest_potter"),
    ("shoemaker", 21, 34, 5, 5, "s", 2, "Дом сапожника", "timber", "shoemaker", None),
    ("midwife", 27, 34, 5, 6, "e", 3, "Дом повитухи Божены", "log", "midwife", None),
    ("boatman", 37, 38, 7, 5, "s", 3, "Дом лодочника", "timber", "boatman", None),
    ("hunter", 46, 38, 6, 5, "s", 2, "Дом охотника", "log", "hunter", None),
    ("healer", 3, 47, 6, 6, "e", 3, "Дом знахаря", "log", "healer", None),
    ("tanner", 22, 47, 5, 5, "s", 2, "Дом кожевника", "timber", "tanner", None),
    ("brzezinski", 28, 46, 5, 8, "e", 3, "Дом семьи Бжезинских", "timber", "big_family", "chest_family"),
    ("baker", 45, 47, 7, 6, "s", 3, "Дом пекаря", "timber", "baker", "chest_baker"),
]
BARNS = [   # амбары и сараи: бревно и солома, рисуются кодом
    ("barn", 12, 47, 9, 7, "s", 4, "Амбар", "barn", "chest_barn"),
    ("shed", 56, 46, 6, 6, "s", 3, "Сарай", "shed", None),
]

# жители: (id, x, y) — где стоят на улице или в доме
VILLAGERS = [
    ("jacek", 8, 10), ("hanna", 30, 17), ("savka", 63, 27), ("agata", 21, 15), ("yurek", 46, 31),
    ("bolek", 47, 15), ("zbyszek", 49, 12), ("matey", 6, 29), ("tomash", 49, 54), ("vlasta", 18, 55),
    ("bozhena", 33, 37), ("stefan", 58, 41),
]

POOL = "BHLNOSdegilmoqtwxyz0346789!&$^-|/()}" + "абвгдежзиклмнопрстуфхцчшэюя"   # свободные буквы: домам, сундукам, жителям


def door_cell(x, y, w, h, side, off):
    return (x + off, y + h - 1) if side == "s" else (x + w - 1, y + off)


def furnish(c, x, y, w, h, door, kind, chest_letter):
    """обстановка дома по виду kind; у двери и в среднем ряду пусто"""
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


LEGEND = {}
LETTERS = {}   # id дома/сундука/жителя -> буква


def letter(key):
    if key not in LETTERS:
        used = set(LETTERS.values()) | set(LEGEND.keys()) | set(F.keys()) | set("#. =_+")
        LETTERS[key] = next(ch for ch in POOL if ch not in used)
    return LETTERS[key]


def build():
    rng = random.Random(77)
    c = Canvas(W, H, "#", seed=31)
    # Ворожея: глубокая вода с бродом, камыши по берегам
    for y in range(1, H - 1):
        wob = int(round(1.2 * math.sin(y / 5.0)))
        for x in RIVER:
            c.put(x + wob, y, "~" if y in FORD else "v")
        for bank in (RIVER.start - 1 + wob, RIVER.stop + wob):
            if y not in FORD and rng.random() < 0.45:
                c.put(bank, y, "j")
            else:
                c.clear(bank, y, bank, y)
    # выходы и точки входа
    c.put(0, 29, "1"); c.put(0, 30, "1")
    for p in [(2, 29), (2, 30), (3, 29), (3, 30)]:
        c.put(*p, "b")
    c.put(W - 1, 30, "2"); c.put(W - 1, 31, "2")
    for p in [(W - 3, 30), (W - 3, 31), (W - 4, 30), (W - 4, 31)]:
        c.put(*p, "f")
    for p in [(43, 33), (44, 33), (43, 34), (44, 34)]:
        c.put(*p, "s")
    c.put(5, 27, "G")
    # улицы: тракт от ворот погоста через площадь к броду, поперечные улицы, площадь
    c.clear(1, 28, W - 2, 32)
    c.clear(33, 2, 35, H - 2)
    c.clear(2, 43, 64, 45)
    c.clear(2, 18, 64, 20)
    c.clear(11, 2, 12, 44)
    c.clear(36, 21, 52, 37)
    c.clear(52, 2, 53, 44)
    # площадь: колодец (2x2), доска объявлений, путевой камень
    c.footprint(44, 28, 2, 2, "W")
    c.put(47, 25, "n"); c.put(40, 33, "@")
    # церковь, колокольня у её крыльца, погостик при церкви
    c.building(14, 3, 11, 8, "C", [(19, 10)])
    c.put(19, 4, "Z"); c.put(19, 5, "P"); c.put(18, 5, "c")
    for yy in (6, 7, 8):
        for xx in (16, 17, 21, 22):
            c.put(xx, yy, "p")
    c.put(15, 4, "I"); c.put(23, 4, "I")
    c.footprint(26, 7, 2, 2, "5")
    c.clear(25, 6, 28, 10)
    for p in [(15, 13), (17, 13), (19, 14), (22, 13), (24, 14), (16, 15), (23, 16)]:
        c.put(*p, "%")
    # дом священника
    c.building(37, 1, 7, 5, "E", [(40, 5)])
    c.put(41, 2, "k"); c.put(38, 2, "D"); c.put(42, 2, "I"); c.put(38, 3, "U")
    # таверна «Пьяный Ворон»: большой зал на северной стороне площади, две двери
    tx, ty, tw, th = 36, 7, 16, 11
    c.building(tx, ty, tw, th, "R", [(43, 17), (51, 12)])
    for (xx, yy, ch) in [(37, 8, "U"), (38, 8, "U"), (39, 8, "I"), (40, 8, "I"), (41, 8, "U"), (44, 8, "V"), (45, 8, "V"),
                         (48, 8, "I"), (49, 8, "U"), (50, 8, "U"), (37, 9, "X"), (37, 10, "U")]:
        c.put(xx, yy, ch)
    for xx in (38, 39, 40, 41, 42):
        c.put(xx, 11, "Q")
    c.put(40, 10, "M")
    for (xx, yy) in [(45, 11), (45, 14), (48, 14), (39, 14)]:   # столы с лавками
        c.put(xx, yy, "Y"); c.put(xx + 1, yy, "J"); c.put(xx - 1, yy, "J")
    c.put(48, 11, "Y"); c.put(48, 10, "J")
    c.put(37, 16, "U"); c.put(50, 16, "X"); c.put(37, 15, "U")
    c.put(43, 12, "K"); c.put(47, 12, "r")
    # кузня Гюнтера у дороги к броду
    c.building(55, 33, 9, 7, "F", [(59, 39)])
    c.put(58, 34, "V"); c.put(59, 34, "V"); c.put(57, 36, "a"); c.put(56, 36, "u"); c.put(60, 36, "A")
    c.put(56, 34, "U"); c.put(62, 34, "X"); c.put(62, 37, "U"); c.put(62, 36, "X"); c.put(56, 38, "I")
    # жилые дома, амбары
    for (hid, x, y, w, h, side, off, name, mat, kind, chest) in HOUSES:
        d = door_cell(x, y, w, h, side, off)
        c.building(x, y, w, h, letter(hid), [d])
        furnish(c, x, y, w, h, d, kind, letter(chest) if chest else None)
    for (hid, x, y, w, h, side, off, name, kind, chest) in BARNS:
        d = door_cell(x, y, w, h, side, off)
        c.building(x, y, w, h, letter(hid), [d])
        furnish(c, x, y, w, h, d, kind, letter(chest) if chest else None)
    # жители
    for (nid, x, y) in VILLAGERS:
        assert c.get(x, y) in "._", (nid, x, y, c.get(x, y))
        c.put(x, y, letter("npc_" + nid))
    # огороды, деревья, плетни
    c.scatter("T", 64, 1, 1, W - 2, H - 2)
    c.scatter(",", 90, 1, 1, W - 2, H - 2)
    return c.rows()


LEGEND.update({
    "T": {"prop": "tree"}, ",": {"prop": "bush", "block": False}, "j": {"prop": "reeds", "block": False},
    "~": {"surface": "water"}, "v": {"surface": "water", "solid": True}, "h": {"solid": True},
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
    # рисунок снаружи — props/bld_<id дома>, его рисует tools/art/buildings.py точно под место дома на карте
    LEGEND[letter(hid)] = {"building": "house_" + hid, "size": [w, h], "name": name, "material": mat,
                           "roof": "thatch" if mat == "log" else "shingle", "sprite": "bld_house_" + hid}
for (hid, x, y, w, h, side, off, name, kind, chest) in BARNS:
    LEGEND[letter(hid)] = {"building": hid, "size": [w, h], "name": name, "material": "log", "roof": "thatch",
                           "sprite": "bld_" + hid}
for chest in sorted({hc[-1] for hc in HOUSES + BARNS if hc[-1]}):
    LEGEND[letter(chest)] = {"object": chest, "look": "chest"}
for (nid, x, y) in VILLAGERS:
    LEGEND[letter("npc_" + nid)] = {"npc": nid}

if __name__ == "__main__":
    rows = build()
    print("\n".join(rows))
    print(check("village", rows, LEGEND, (3, 29)))
    sizes = sorted({(h[3], h[4], h[8]) for h in HOUSES})
    print("house sizes:", sizes)
