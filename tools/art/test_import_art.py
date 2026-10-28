"""Тесты импорта картинок на искусственных листах. Запуск: python -m unittest discover tools/art"""

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).parent))
import import_art  # noqa: E402

DATA = Path(__file__).resolve().parents[2] / "data"


def figure(size, color=(200, 60, 40, 255), box=(0.3, 0.15, 0.7, 0.95), shift=0):
    """Кадр с «персонажем»: прямоугольник с головой, на прозрачном фоне."""
    w, h = size
    img = Image.new("RGBA", size)
    d = ImageDraw.Draw(img)
    x0, y0, x1, y1 = int(box[0] * w) + shift, int(box[1] * h), int(box[2] * w) + shift, int(box[3] * h)
    d.rectangle((x0, y0 + (y1 - y0) // 4, x1, y1), fill=color)
    d.ellipse((x0 + 2, y0, x1 - 2, y0 + (y1 - y0) // 3), fill=color)
    return img


def sheet(frames_by_row, size, gap=0, margin=0, bg=(0, 0, 0, 0)):
    cols = max(len(r) for r in frames_by_row)
    w, h = size
    out = Image.new("RGBA", (2 * margin + cols * w + (cols - 1) * gap, 2 * margin + len(frames_by_row) * h
                             + (len(frames_by_row) - 1) * gap), bg)
    for r, row in enumerate(frames_by_row):
        for c, f in enumerate(row):
            out.alpha_composite(f, (margin + c * (w + gap), margin + r * (h + gap)))
    return out


class ImportTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        (self.root / "data").mkdir()
        for f in DATA.glob("*.json"):
            if f.name != "sprites.json":
                shutil.copy(f, self.root / "data" / f.name)
        self.inbox = self.root / "art" / "inbox"
        self.inbox.mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.root)

    def put(self, rel, img):
        p = self.inbox / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        img.save(p)
        return p

    def run_import(self, **kw):
        return import_art.run(self.root, quiet=True, **kw)

    def test_strip_files_become_animations(self):
        idle = sheet([[figure((48, 64), shift=s) for s in (0, 1, 2, 1)]], (48, 64))
        walk = sheet([[figure((48, 64), shift=s) for s in range(-3, 3)]], (48, 64))
        self.put("Wolf/Wolf_Idle.png", idle)
        self.put("Wolf/Wolf_Run.png", walk)
        self.put("Wolf/Wolf_Death.png", sheet([[figure((48, 64))] * 3], (48, 64)))
        res = self.run_import()
        wolf = res["catalog"]["wolf"]
        self.assertEqual(wolf["animations"]["idle"]["count"], 4)
        self.assertEqual(wolf["animations"]["walk"]["count"], 6)
        self.assertFalse(wolf["animations"]["death"]["loop"])
        self.assertEqual(res["bindings"]["units"]["wolf"], "wolf")
        self.assertIn("units/wolf", res["bindings"]["auto"])
        self.assertTrue((self.root / "art" / "sprites" / "wolf.png").exists())
        self.assertTrue((self.root / "art" / "review" / "bindings.png").exists())

    def test_grid_with_gaps_and_row_animations(self):
        rows = [[figure((32, 32), shift=i % 3) for i in range(n)] for n in (4, 6, 3)]
        self.put("goblin_shaman.png", sheet(rows, (32, 32), gap=2, margin=1))
        res = self.run_import()
        e = res["catalog"]["goblin_shaman"]
        counts = [a["count"] for a in e["animations"].values()]
        self.assertEqual(counts, [4, 6, 3])
        self.assertEqual(res["bindings"]["units"]["goblin_shaman"], "goblin_shaman")

    def test_touching_frames_square_strip(self):
        frames = [figure((40, 40), box=(0.0, 0.1, 1.0, 1.0)) for _ in range(5)]
        self.put("fire_fx.png", sheet([frames], (40, 40)))
        res = self.run_import()
        self.assertEqual(res["catalog"]["fire_fx"]["animations"]["idle"]["count"], 5)
        self.assertEqual(res["catalog"]["fire_fx"]["kind"], "effect")
        self.assertEqual(res["bindings"]["surfaces"]["fire"], "fire_fx")

    def test_sequence_files(self):
        for i in range(4):
            self.put("knight/knight_walk_%d.png" % i, figure((50, 70), shift=i))
        self.put("knight/knight_attack_0.png", figure((50, 70), color=(10, 10, 200, 255)))
        self.put("knight/knight_attack_1.png", figure((50, 70), color=(10, 10, 220, 255)))
        res = self.run_import()
        anims = res["catalog"]["knight"]["animations"]
        self.assertEqual(anims["walk"]["count"], 4)
        self.assertEqual(anims["attack"]["count"], 2)

    def test_two_attack_strips_are_two_animations(self):
        self.put("hero/Attack1.png", sheet([[figure((40, 50))] * 5], (40, 50)))
        self.put("hero/Attack2.png", sheet([[figure((40, 50))] * 3], (40, 50)))
        res = self.run_import()
        anims = res["catalog"]["hero"]["animations"]
        self.assertEqual(anims["attack"]["count"], 5)
        self.assertEqual(anims["attack2"]["count"], 3)

    def test_white_background_is_removed(self):
        """Рисунок (гравюра) на белой бумаге: фон уходит, белые места внутри фигуры остаются."""
        img = Image.new("RGB", (300, 400), (250, 248, 240))
        d = ImageDraw.Draw(img)
        d.ellipse((90, 60, 210, 360), fill=(30, 25, 20))
        d.ellipse((130, 120, 170, 160), fill=(252, 250, 245))      # белое пятно внутри фигуры
        noise = np.random.default_rng(1).integers(-6, 7, (400, 300, 3))
        arr = np.clip(np.asarray(img).astype(int) + noise, 0, 255).astype(np.uint8)
        self.put("wizard.jpg", Image.fromarray(arr))
        res = self.run_import()
        e = res["catalog"]["wizard"]
        self.assertEqual(res["bindings"]["units"]["wizard"], "wizard")
        out = np.asarray(Image.open(self.root / "art" / "sprites" / "wizard.png"))
        self.assertEqual(out[1, 1, 3], 0)
        fw, fh = e["frame"]
        self.assertLess(fw, 140)                                   # поля обрезаны по фигуре
        self.assertEqual(out[1 + fh // 2, 1 + fw // 2, 3], 255)
        self.assertEqual(out[1 + 80, 1 + 60, 3], 255)              # белое пятно внутри не стало дырой

    def test_pixelate(self):
        """settings.pixelate: рисованная фигура и текстура становятся пиксель-артом, пиксельный пак не трогается."""
        (self.root / "data" / "sprites.json").write_text(json.dumps({"settings": {
            "texture_cells": 3, "pixelate": {"unit": 48, "cell": 16, "colors": 8, "tile_colors": 6}}}))
        rng = np.random.default_rng(3)
        smooth = np.zeros((600, 400, 4), np.uint8)
        smooth[..., 0] = np.linspace(0, 255, 400)[None, :]
        smooth[..., 1] = np.linspace(0, 255, 600)[:, None]
        smooth[..., 2] = rng.integers(0, 255, (600, 400))
        smooth[60:580, 100:300, 3] = 255
        self.put("wizard.png", Image.fromarray(smooth))
        (self.inbox / "wizard.art.json").write_text('{"kind": "unit"}')
        x = np.linspace(0, 2 * np.pi, 512, endpoint=False)
        wave = (127 + 120 * np.cos(x)[None, :] * np.cos(x)[:, None]).astype(np.uint8)     # бесшовный узор
        hue = (127 + 120 * np.cos(2 * x)[:, None] * np.cos(3 * x)[None, :]).astype(np.uint8)
        self.put("floor.png", Image.fromarray(np.dstack([wave, hue, 255 - wave, np.full_like(wave, 255)])))
        self.put("goblin.png", figure((32, 32)))                  # уже пиксель-арт: два цвета, резкие края
        res = self.run_import()
        cat = res["catalog"]
        self.assertTrue(cat["wizard"]["pixel_art"])
        fw, fh = cat["wizard"]["frame"]
        self.assertEqual(fh, 48 + 2)                               # рост юнита + обводка
        out = np.asarray(Image.open(self.root / "art" / "sprites" / "wizard.png"))
        frame = out[1:1 + fh, 1:1 + fw]
        self.assertTrue(set(np.unique(frame[..., 3])) <= {0, 255})  # резкие края
        visible = frame[frame[..., 3] > 0][:, :3]
        self.assertLessEqual(len({tuple(c) for c in visible}), 8 + 1)    # палитра + цвет обводки
        self.assertIn(tuple(import_art.OUTLINE_COLOR), {tuple(c) for c in visible})
        self.assertEqual(cat["floor"]["frame"], [48, 48])           # клетка 16 × texture_cells
        tile = np.asarray(Image.open(self.root / "art" / "sprites" / "floor.png"))[1:49, 1:49, :3].astype(int)
        self.assertLessEqual(len({tuple(c) for c in tile.reshape(-1, 3)}), 6)
        inner = np.abs(np.diff(tile, axis=1)).mean()
        seam = np.abs(tile[:, 0] - tile[:, -1]).mean()
        self.assertLessEqual(seam, inner)                            # остаётся бесшовной
        x0, y0, x1, y1 = import_art.bbox_union([figure((32, 32))])
        self.assertEqual(cat["goblin"]["frame"], [x1 - x0, y1 - y0])   # пиксельный спрайт как был, без обводки

    def test_pixel_tone(self):
        """pixel_tone из подсказки: та же картинка с яркостью 0.6 выходит темнее."""
        (self.root / "data" / "sprites.json").write_text(json.dumps({"settings": {"pixelate": {"enabled": True}}}))
        rng = np.random.default_rng(5)
        img = np.zeros((300, 300, 4), np.uint8)
        img[..., :3] = rng.integers(150, 250, (300, 300, 3))
        img[40:280, 60:240, 3] = 255
        for name, tone in (("hut", None), ("dark_hut", [0.6, 1.0])):
            self.put(name + ".png", Image.fromarray(img))
            hint = {"kind": "image", "cols": 1, "rows_count": 1, "pixel_box": [40, 40]}
            if tone:
                hint["pixel_tone"] = tone
            (self.inbox / (name + ".art.json")).write_text(json.dumps(hint))
        self.run_import()

        def mean(name):
            a = np.asarray(Image.open(self.root / "art" / "sprites" / (name + ".png")).convert("RGBA")).astype(int)
            return a[a[..., 3] > 0][:, :3].mean()
        self.assertLess(mean("dark_hut"), mean("hut") * 0.75)

    def test_magenta_key(self):
        rows = [[figure((32, 32))] * 3]
        img = sheet(rows, (32, 32), bg=(255, 0, 255, 255))
        self.put("slime_walk.png", img)
        res = self.run_import()
        out = np.asarray(Image.open(self.root / "art" / "sprites" / "slime.png"))
        self.assertEqual(res["catalog"]["slime"]["animations"]["walk"]["count"], 3)
        visible = out[out[..., 3] > 0][:, :3]
        self.assertFalse(((visible == [255, 0, 255]).all(axis=1)).any())

    def test_opaque_tileset(self):
        rng = np.random.default_rng(2)
        tiles = Image.new("RGB", (16 * 6, 16 * 4))
        for y in range(4):
            for x in range(6):
                base = rng.integers(40, 220, 3)
                arr = np.clip(base + rng.integers(-10, 10, (16, 16, 3)), 0, 255).astype(np.uint8)
                tiles.paste(Image.fromarray(arr), (x * 16, y * 16))
        self.put("dungeon_tiles.png", tiles)
        res = self.run_import()
        e = res["catalog"]["dungeon_tiles"]
        self.assertEqual(e["kind"], "tileset")
        self.assertEqual((e["cols"], e["count"], e["frame"]), (6, 24, [16, 16]))
        self.assertTrue(e.get("opaque"))

    def test_lpc_layout(self):
        img = Image.new("RGBA", (832, 1344))
        for r, (name, count) in enumerate(import_art.LPC_ROWS):
            for c in range(count):
                img.alpha_composite(figure((64, 64), box=(0.3, 0.2, 0.7, 0.95)), (c * 64, r * 64))
        self.put("ranger.png", img)
        res = self.run_import()
        anims = res["catalog"]["ranger"]["animations"]
        self.assertEqual(anims["walk_left"]["count"], 8)
        self.assertEqual(anims["idle_down"]["count"], 1)
        self.assertEqual(anims["attack_right"]["count"], 6)
        self.assertIn("death", anims)

    def test_aseprite_json(self):
        frames, tags = {}, []
        img = Image.new("RGBA", (5 * 24, 24))
        for i in range(5):
            img.alpha_composite(figure((24, 24)), (i * 24, 0))
            frames["cleric %d.aseprite" % i] = {"frame": {"x": i * 24, "y": 0, "w": 24, "h": 24}, "duration": 125}
        tags = [{"name": "Idle", "from": 0, "to": 1}, {"name": "Hurt", "from": 2, "to": 4}]
        self.put("cleric.png", img)
        (self.inbox / "cleric.json").write_text(json.dumps({"frames": frames, "meta": {"image": "cleric.png",
                                                                                         "frameTags": tags}}))
        res = self.run_import()
        anims = res["catalog"]["cleric"]["animations"]
        self.assertEqual((anims["idle"]["count"], anims["hurt"]["count"]), (2, 3))
        self.assertEqual(anims["idle"]["fps"], 8.0)

    def test_override_rows(self):
        rows = [[figure((40, 40), box=(0.0, 0.0, 1.0, 1.0))] * 4 for _ in range(2)]
        self.put("dummy.png", sheet(rows, (40, 40)))
        (self.inbox / "dummy.art.json").write_text(json.dumps({"frame": [40, 40], "rows": ["idle", "hurt"]}))
        res = self.run_import()
        anims = res["catalog"]["dummy"]["animations"]
        self.assertEqual(list(anims), ["idle", "hurt"])
        self.assertEqual(res["bindings"]["units"]["training_dummy"], "dummy")

    def test_zip_and_manual_bindings_survive(self):
        tmp = self.root / "pack"
        tmp.mkdir()
        figure((40, 60)).save(tmp / "orc.png")
        figure((40, 60)).save(tmp / "wolf.png")
        import zipfile
        with zipfile.ZipFile(self.inbox / "monsters.zip", "w") as z:
            z.write(tmp / "orc.png", "monsters/orc.png")
            z.write(tmp / "wolf.png", "monsters/wolf.png")
        (self.root / "data" / "sprites.json").write_text(json.dumps({"units": {"goblin_warrior": "orc"}}))
        res = self.run_import()
        self.assertEqual(res["bindings"]["units"]["goblin_warrior"], "orc")
        self.assertEqual(res["bindings"]["units"]["wolf"], "wolf")
        self.assertNotIn("units/goblin_warrior", res["bindings"]["auto"])
        # спрайт удалили из входящих: авто-привязка исчезает, ручная остаётся (и попадает в отчёт)
        (self.inbox / "monsters.zip").unlink()
        res = self.run_import()
        self.assertNotIn("wolf", res["bindings"]["units"])
        self.assertEqual(res["bindings"]["units"]["goblin_warrior"], "orc")
        self.assertTrue(res["broken"])
        self.assertFalse((self.root / "art" / "sprites" / "wolf.png").exists())

    def test_irregular_pieces(self):
        img = Image.new("RGBA", (300, 80))
        x = 4
        for w in (30, 44, 36, 50):
            img.alpha_composite(figure((w, 70), box=(0.0, 0.0, 1.0, 1.0)), (x, 5))
            x += w + 17
        self.put("bat_run.png", img)
        res = self.run_import()
        self.assertEqual(res["catalog"]["bat"]["animations"]["walk"]["count"], 4)

    def test_directions_without_animation(self):
        self.put("wolf_left.png", figure((40, 50)))
        self.put("wolf_right.png", figure((40, 50), shift=3))
        res = self.run_import()
        self.assertEqual(sorted(res["catalog"]["wolf"]["animations"]), ["idle_left", "idle_right"])

    def test_names(self):
        n = import_art.parse_name("femaleAdventurer_walk3")
        self.assertEqual((n.base, n.anim, n.number), (["female", "adventurer"], "walk", 3))
        n = import_art.parse_name("Knight_Attack2")
        self.assertEqual((n.anim, n.number), ("attack", 2))
        n = import_art.parse_name("orc_walk_left_strip8")
        self.assertEqual((n.base, n.anim, n.direction, n.hints), (["orc"], "walk", "left", {"count": 8}))
        n = import_art.parse_name("Волк_бег")
        self.assertEqual((import_art.slug(n.base), n.anim), ("volk", "walk"))
        n = import_art.parse_name("гоблин_удар2")
        self.assertEqual((n.base, n.anim, n.number), (["гоблин"], "attack", 2))


if __name__ == "__main__":
    unittest.main()
