"""Тесты генератора на поддельном ComfyUI. Запуск: python -m unittest discover tools/art"""

import io
import json
import shutil
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).parent))
import generate  # noqa: E402
import import_art  # noqa: E402

DATA = Path(__file__).resolve().parents[2] / "data"


class FakeComfy(BaseHTTPRequestHandler):
    """Отвечает как ComfyUI: модели, очередь, история, картинка по размеру из схемы."""
    prompts: dict = {}

    def log_message(self, *a):
        pass

    def reply(self, data, ctype="application/json"):
        body = data if isinstance(data, bytes) else json.dumps(data).encode()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path
        if path == "/system_stats":
            return self.reply({"system": {"comfyui_version": "test"}, "devices": [{"name": "fake", "vram_total": 6 << 30}]})
        if path == "/object_info/CheckpointLoaderSimple":
            return self.reply({"CheckpointLoaderSimple": {"input": {"required": {
                "ckpt_name": [["sd_xl_base_1.0.safetensors"], {}]}}}})
        if path == "/object_info/LoraLoader":
            return self.reply({"LoraLoader": {"input": {"required": {
                "lora_name": ["COMBO", {"options": ["detail.safetensors", "Woodcut_SDXL.safetensors"]}]}}}})
        if path.startswith("/history/"):
            pid = path.split("/")[-1]
            return self.reply({pid: {"status": {"status_str": "success", "completed": True},
                                     "outputs": {"8": {"images": [{"filename": pid + ".png", "subfolder": "",
                                                                   "type": "temp"}]}}}})
        if path.startswith("/view?"):
            pid = path.split("filename=")[1].split(".png")[0]
            return self.reply(self.picture(self.prompts[pid]), "image/png")
        self.send_error(404)

    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        pid = "p%d" % len(self.prompts)
        FakeComfy.prompts[pid] = data["prompt"]
        self.reply({"prompt_id": pid, "number": len(self.prompts), "node_errors": {}})

    @staticmethod
    def picture(wf) -> bytes:
        w, h = wf["5"]["inputs"]["width"], wf["5"]["inputs"]["height"]
        text = wf["3"]["inputs"]["text"]
        rng = np.random.default_rng(wf["6"]["inputs"]["seed"] % 1000)
        if "seamless texture" in text:
            img = Image.fromarray(rng.integers(40, 200, (h, w, 3), dtype=np.uint8), "RGB")
        elif "black background" in text:
            img = Image.new("RGB", (w, h), (0, 0, 0))
            ImageDraw.Draw(img).ellipse((w // 4, h // 4, 3 * w // 4, 3 * h // 4), fill=(230, 230, 230))
        else:
            img = Image.new("RGB", (w, h), (252, 251, 248))
            d = ImageDraw.Draw(img)
            d.rectangle((w // 3, h // 5, 2 * w // 3, 4 * h // 5), fill=(160, 40, 30))
            if "a hovering shield" in text:
                d.ellipse((w // 20, h // 3, w // 4, h // 2), fill=(60, 60, 160))   # щит висит отдельно от фигуры
        buf = io.BytesIO()
        img.save(buf, "PNG")
        return buf.getvalue()


class GenerateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), FakeComfy)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.url = "http://127.0.0.1:%d" % cls.server.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        (self.root / "data").mkdir()
        for f in DATA.glob("*.json"):
            if f.name != "sprites.json":
                shutil.copy(f, self.root / "data" / f.name)
        full = generate.load_prompts()
        self.prompts = {k: full[k] for k in ("settings", "styles", "negative", "kinds")}
        self.prompts.update({
            "units": {"knight": full["units"]["knight"]},
            "tiles": {"village/floor": "dirt", "forest/wall": {"kind": "object", "subject": "an oak tree"}},
            "surfaces": {"steam": "steam"},
            "skills": {"attack": "a sword"},
            "statuses": {"knocked_down": "a falling figure"},
            "props": {"open_grave": {"subject": "a grave", "px": [36, 24],
                                     "bind": ["props/open_grave", "props/fresh_grave"]}},
        })
        self.items = generate.items_of(self.prompts, self.root / "data")
        self.comfy = generate.Comfy([self.url], log=lambda *a: None)

    def tearDown(self):
        shutil.rmtree(self.root)

    def test_items(self):
        by = {it.key: it for it in self.items}
        self.assertEqual(by["tiles/village/floor"].bind, "locations/village/floor")
        self.assertEqual(by["tiles/village/floor"].kind, "texture")
        self.assertEqual(by["tiles/forest/wall"].kind, "object")
        self.assertEqual(by["tiles/forest/wall"].out_id, "forest_wall")
        self.assertEqual(by["surfaces/steam"].kind, "cloud")     # слой cloud в surfaces.json
        self.assertEqual(by["skills/attack"].kind, "icon")
        self.assertEqual([it.key for it in generate.select(self.items, ["tiles"])],
                         ["tiles/village/floor", "tiles/forest/wall"])

    def test_generate_pick_and_import(self):
        made = generate.generate(self.root, self.prompts, self.items, 2, "color", self.comfy, log=lambda *a: None)
        self.assertEqual(len(made), 2 * len(self.items))
        wf = next(iter(FakeComfy.prompts.values()))
        self.assertEqual(wf["2"]["inputs"]["lora_name"], "Woodcut_SDXL.safetensors")   # «auto» нашла гравюру
        unit_wf = [w for w in FakeComfy.prompts.values() if "knight" in w["3"]["inputs"]["text"]][0]
        self.assertEqual((unit_wf["5"]["inputs"]["width"], unit_wf["5"]["inputs"]["height"]), (832, 1216))
        knight = next(it for it in self.items if it.key == "units/knight")
        self.assertEqual([generate.variant_number(v) for v in generate.variants(self.root, knight)], [1, 2])
        steam = Image.open(generate.variants(self.root, next(it for it in self.items if it.gid == "steam"))[0])
        self.assertEqual(steam.mode, "RGBA")                     # облако с чёрного фона стало полупрозрачным
        self.assertEqual(steam.getpixel((0, 0))[3], 0)

        record = {}
        for it in self.items:
            generate.pick(self.root, it, 2, record, self.prompts)
        self.assertEqual(record["units/knight"]["variant"][:3], "v02")
        self.assertIn("seed", record["units/knight"])
        hint = json.loads((self.root / "art/inbox/generated/skills/attack.art.json").read_text(encoding="utf-8"))
        self.assertEqual(hint["id"], "attack")
        hint = json.loads((self.root / "art/inbox/generated/props/open_grave.art.json").read_text(encoding="utf-8"))
        self.assertEqual(hint["pixel_box"], [36, 24])
        self.assertEqual(hint["kind"], "image")
        sheet = generate.contact_sheet(self.root, "units", self.items, record, self.prompts)
        self.assertTrue(sheet.exists())

        res = import_art.run(self.root, quiet=True)
        b = res["bindings"]
        self.assertEqual(b["units"]["knight"], "knight")
        self.assertEqual(b["skills"]["attack"], "attack")        # «attack» не стал анимацией
        self.assertEqual(b["statuses"]["knocked_down"], "knocked_down")   # «down» не стал направлением
        self.assertEqual(b["surfaces"]["steam"], "steam")
        self.assertEqual(b["locations"]["village"]["floor"], "village_floor")
        self.assertEqual(b["locations"]["forest"]["wall"], "forest_wall")
        self.assertIn("locations/forest/wall", b["auto"])
        self.assertEqual(b["props"], {"open_grave": "open_grave", "fresh_grave": "open_grave"})   # одна на два id
        cat = res["catalog"]
        self.assertTrue(cat["village_floor"].get("opaque"))      # фон текстуры не срезан
        self.assertFalse(cat["forest_wall"].get("opaque"))       # дерево вырезано с белого фона
        self.assertEqual(cat["knight"]["kind"], "unit")
        self.assertEqual(cat["knight"]["count"], 1)

        # ручная привязка сильнее подсказки, а пропавшая картинка снимает свою привязку
        b["units"]["knight"] = "attack"
        b["auto"].remove("units/knight")
        (self.root / "data/sprites.json").write_text(json.dumps(b), encoding="utf-8")
        for f in (self.root / "art/inbox/generated/tiles").glob("forest_wall*"):
            f.unlink()
        res = import_art.run(self.root, quiet=True)
        self.assertEqual(res["bindings"]["units"]["knight"], "attack")
        self.assertNotIn("forest", res["bindings"].get("locations", {}))
        self.assertNotIn("locations/forest/wall", res["bindings"]["auto"])
        self.assertEqual(res["bindings"]["locations"]["village"]["floor"], "village_floor")

    def test_figure_problems(self):
        def fig(extra=None, box=(0.3, 0.2, 0.7, 0.8)):
            w, h = 400, 600
            img = Image.new("RGB", (w, h), (233, 216, 178))          # бумажный фон, как у LoRA гравюры
            d = ImageDraw.Draw(img)
            d.rectangle((int(box[0] * w), int(box[1] * h), int(box[2] * w), int(box[3] * h)), fill=(40, 30, 20))
            if extra:
                d.ellipse(extra, fill=(60, 60, 160))
            return img
        self.assertEqual(generate.figure_problems(fig()), [])
        self.assertEqual(generate.figure_problems(fig(extra=(20, 200, 100, 300))), ["отдельный предмет"])
        self.assertEqual(generate.figure_problems(fig(extra=(150, 150, 152, 152))), [])   # крапинка не в счёт
        self.assertEqual(generate.figure_problems(fig(box=(0.3, 0.2, 0.7, 1.0))), ["обрезано краем"])
        self.assertEqual(generate.figure_problems(Image.new("RGB", (400, 600), (40, 30, 20))), ["фон не убрался"])

    def test_cut_figure_removes_paper_between_feet(self):
        paper, ink = (233, 216, 178), (40, 30, 20)
        img = Image.new("RGB", (300, 400), paper)
        d = ImageDraw.Draw(img)
        d.rectangle((100, 60, 200, 300), fill=ink)                  # тело
        d.rectangle((110, 120, 190, 200), fill=paper)                # светлый плащ внутри фигуры — остаётся
        d.rectangle((100, 300, 200, 360), outline=ink, width=6)      # ноги и тень, внутри бумага
        out = np.asarray(generate.cut_figure(img))
        self.assertEqual(out[10, 10, 3], 0)                          # фон
        self.assertEqual(out[330, 150, 3], 0)                        # бумага между ног
        self.assertEqual(out[160, 150, 3], 255)                      # плащ
        self.assertEqual(out[200, 102, 3], 255)                      # тело

    def test_retry_when_all_variants_are_bad(self):
        bad = generate.Item("units/knight", "units", "knight", "knight", "units/knight", "unit", "a hovering shield")
        prompts = dict(self.prompts, settings=dict(self.prompts["settings"], retries=2))
        made = generate.generate(self.root, prompts, [bad], 1, "color", self.comfy, log=lambda *a: None)
        self.assertEqual(len(made), 3)                    # 1 вариант + 2 попытки, все с отдельным щитом
        meta = json.loads(made[-1].with_suffix(".json").read_text(encoding="utf-8"))
        self.assertEqual(meta["problems"], ["отдельный предмет"])
        good = generate.Item("units/wolf", "units", "wolf", "wolf", "units/wolf", "unit", "a wolf")
        self.assertEqual(len(generate.generate(self.root, prompts, [good], 1, "color", self.comfy,
                                               log=lambda *a: None)), 1)

    def test_settings_order(self):
        it = generate.Item("units/knight", "units", "knight", "knight", "units/knight", "unit", "x", {"steps": 30})
        prompts = {"settings": {"steps": 25, "cfg": 6.5, "variants": 3, "checkpoint": "base.safetensors",
                                "models": {"turbo": {"steps": 8, "cfg": 2.0}}},
                   "kinds": {"unit": {"variants": 4}}}
        self.assertEqual(generate.setting(prompts, it, "steps"), 30)                    # своё у картинки
        self.assertEqual(generate.setting(prompts, it, "variants"), 4)                  # у вида
        self.assertEqual(generate.setting(prompts, it, "cfg"), 6.5)                     # общее
        self.assertEqual(generate.setting(prompts, it, "cfg", checkpoint="DreamShaperXL_Turbo.safetensors"), 2.0)

    def test_tileable(self):
        # плавный перепад слева направо и сверху вниз: у исходной картинки края сильно разные
        y, x = np.mgrid[0:64, 0:96]
        g = np.dstack([x * 255 // 95, y * 255 // 63, (x + y) * 255 // 158]).astype(np.uint8)
        a = np.asarray(generate.make_tileable(Image.fromarray(g, "RGB"))).astype(int)
        step = max(np.abs(np.diff(a, axis=1)).max(), np.abs(np.diff(a, axis=0)).max())
        self.assertGreater(np.abs(g[:, 0].astype(int) - g[:, -1]).mean(), 100)
        self.assertLessEqual(np.abs(a[:, 0] - a[:, -1]).max(), step)    # стык копий не резче соседних пикселей
        self.assertLessEqual(np.abs(a[0] - a[-1]).max(), step)


if __name__ == "__main__":
    unittest.main()
