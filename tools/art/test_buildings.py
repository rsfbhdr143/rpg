"""Тесты домов из tools/art/buildings.py. Запуск: python -m unittest discover tools/art"""

import json
import shutil
import sys
import tempfile
import unittest
import warnings
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import buildings  # noqa: E402
import import_art  # noqa: E402

DATA = Path(__file__).resolve().parents[2] / "data"

MAP = {
    "town": {
        "rows": [
            "..........",
            ".A=====...",
            ".=_A__=...",
            ".=____+...",
            ".==+===...",
            "..........",
        ],
        "legend": {"A": {"building": "house_A", "size": [6, 4], "material": "timber", "roof": "shingle"}},
    }
}


class BuildingsTest(unittest.TestCase):
    def setUp(self):
        warnings.simplefilter("ignore", RuntimeWarning)     # переполнение в хеш-шуме — нарочно

    def test_letter_inside_house_is_not_a_house(self):
        found = buildings.scene_from_cells(MAP, warn=False)
        self.assertEqual([b["rect"] for b in found], [[1, 1, 6, 4]])
        self.assertEqual(sorted(map(tuple, found[0]["doors"])), [(3, 4), (6, 3)])

    def test_near_corner_is_bottom_middle(self):
        b = buildings.scene_from_cells(MAP, warn=False)[0]
        img = buildings.render_building(b)
        a = np.asarray(img)[..., 3] > 0
        cols = np.nonzero(a.any(axis=0))[0]
        left, right = img.width / 2 - cols[0], cols[-1] + 1 - img.width / 2
        self.assertLessEqual(abs(left - right), 4)                                   # середина холста — середина ромба
        bottom = np.nonzero(a.any(axis=1))[0][-1]
        self.assertGreaterEqual(bottom, img.height - 2)                              # ближний угол у нижнего края
        corner = img.width // 2 + 8 * (6 - 4)                                        # он правее середины на 8(w - h)
        self.assertTrue(a[bottom - 1, corner - 1: corner + 2].any())
        want = (6 + 4) * 16                                                          # игра берёт рисунок, если ширина
        self.assertLessEqual(abs(img.width / want - 1), 0.15)                        # совпала с местом дома на 15%

    def test_import_keeps_canvas(self):
        root = Path(tempfile.mkdtemp())
        try:
            (root / "data").mkdir()
            for f in DATA.glob("*.json"):
                if f.name != "sprites.json":
                    shutil.copy(f, root / "data" / f.name)
            out = root / "art" / "inbox" / "buildings"
            b = buildings.scene_from_cells(MAP, warn=False)[0]
            img = buildings.render_building(b)
            buildings.save(img, out, buildings.sprite_id(b["id"]), "props/bld_" + b["id"])
            import_art.run(root, quiet=True)
            entry = json.loads((root / "data" / "sprites.json").read_text(encoding="utf-8"))
            self.assertEqual(entry["props"]["bld_house_A"], "bld_house_aa")         # house_A и house_a не путаются
            cat = json.loads((root / "art" / "catalog.json").read_text(encoding="utf-8"))["assets"]["bld_house_aa"]
            self.assertEqual(cat["frame"], [img.width, img.height])                 # холст не обрезан и не сжат
            self.assertTrue(cat["pixel_art"])
        finally:
            shutil.rmtree(root)


if __name__ == "__main__":
    unittest.main()
