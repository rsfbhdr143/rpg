#!/usr/bin/env python3
"""Картинки для игры из Stable Diffusion (ComfyUI на этом компьютере).

    python tools/art/generate.py                        # всё, для чего ещё нет вариантов: по 3 штуки
    python tools/art/generate.py units/knight skills    # только эти: id или целая категория
    python tools/art/generate.py --more units/knight    # ещё варианты, с новыми зёрнами
    python tools/art/generate.py --pick units/knight=2 skills/fireball=1    # выбрать вариант для игры
    python tools/art/generate.py --list                 # что описано, сколько вариантов, что выбрано
    python tools/art/generate.py --checkpoint other.safetensors units/knight    # попробовать другую модель

Что рисовать и в каком стиле, написано в tools/art/prompts.json. Варианты ложатся в art/generated/<категория>/<id>/
(в git не попадают), для каждой категории рисуется лист сравнения art/generated/<категория>.png с номерами.
Фигуры проверяются сами: не убрался фон, фигура обрезана краем, рядом висит отдельный предмет (щит, меч).
Такие варианты помечаются красным, и если плохи все, скрипт дорисовывает ещё (settings.retries).
Выбранный вариант копируется в art/inbox/generated/<категория>/<id>.webp вместе с подсказкой для импорта
(точное имя и привязка к игре), а зерно и текст запроса записываются в tools/art/generated.json: по ним
картинку можно повторить. После выбора запусти tools/art/import_art.py.

Нужен установленный ComfyUI. Если он не запущен, скрипт сам откроет Comfy Desktop или запустит портативную
версию из папки comfy_dir (настройки в prompts.json, папку можно задать и переменной окружения COMFYUI_DIR).
Портативную версию скрипт закрывает после работы, Comfy Desktop оставляет открытым.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import random
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import import_art  # noqa: E402  (заодно проверяет, что стоят pillow и numpy)
from import_art import Image, ImageDraw, np  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
PROMPTS = Path(__file__).with_name("prompts.json")
RECORD = Path(__file__).with_name("generated.json")
CATEGORIES = ("units", "tiles", "surfaces", "skills", "statuses")
DEFAULT_KIND = {"units": "unit", "skills": "icon", "statuses": "icon", "surfaces": "texture"}
# во что превращается картинка при импорте: вид спрайта и надо ли убирать фон
IMPORT_KIND = {"unit": "unit", "object": "image", "icon": "icon", "texture": "tile", "wall": "tile", "cloud": "effect"}
KEEP_BACKGROUND = {"texture", "wall"}
LORA_HINT = re.compile(r"wood|lino|engrav|etch|wdct", re.I)


# --- Что рисовать ---------------------------------------------------------------

@dataclass
class Item:
    key: str           # "units/knight", "tiles/forest/wall"
    category: str
    gid: str           # id в игре: "knight", для клеток "forest/wall" или "floor"
    out_id: str        # имя спрайта: "knight", "forest_wall"
    bind: str          # куда привязать: "units/knight", "locations/forest/wall"
    kind: str          # unit, object, icon, texture, wall, cloud
    subject: str
    extra: dict = field(default_factory=dict)


def load_prompts(path: Path = PROMPTS) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def cloud_surfaces(data_dir: Path) -> set[str]:
    p = data_dir / "surfaces.json"
    table = json.loads(p.read_text(encoding="utf-8")).get("surfaces", {}) if p.exists() else {}
    return {sid for sid, d in table.items() if d.get("layer") == "cloud"}


def items_of(prompts: dict, data_dir: Path) -> list[Item]:
    clouds = cloud_surfaces(data_dir)
    out = []
    for cat in CATEGORIES:
        for gid, spec in prompts.get(cat, {}).items():
            spec = {"subject": spec} if isinstance(spec, str) else dict(spec)
            if cat == "tiles":
                parts = gid.split("/")
                tile = parts[-1]
                kind = "wall" if tile == "wall" else "texture"
                bind = "locations/%s/%s" % (parts[0], tile) if len(parts) == 2 else "tiles/" + tile
            else:
                kind = "cloud" if cat == "surfaces" and gid in clouds else DEFAULT_KIND[cat]
                bind = "%s/%s" % (cat, gid)
            kind = str(spec.pop("kind", kind))
            subject = str(spec.pop("subject", gid.replace("_", " ")))
            out.append(Item("%s/%s" % (cat, gid), cat, gid, gid.replace("/", "_"), bind, kind, subject, spec))
    return out


def select(items: list[Item], wanted: list[str]) -> list[Item]:
    if not wanted:
        return items
    picked = []
    for w in wanted:
        w = w.strip("/")
        found = [it for it in items if it.key == w or it.category == w or it.key.startswith(w + "/")
                 or it.gid == w or it.out_id == w]
        if not found:
            sys.exit("Не нашёл «%s» в %s. Есть: %s" % (w, PROMPTS.name, ", ".join(it.key for it in items)))
        picked += [it for it in found if it not in picked]
    return picked


def setting(prompts: dict, item: Item | None, name: str, default=None, checkpoint: str = ""):
    """Настройка: своя у картинки -> у вида (unit, icon ...) -> у модели (settings.models) -> общая."""
    s = prompts.get("settings", {})
    if item is not None and name in item.extra:
        return item.extra[name]
    kind = prompts.get("kinds", {}).get(item.kind, {}) if item is not None else {}
    if name in kind:
        return kind[name]
    ckpt = (checkpoint or str(s.get("checkpoint", ""))).lower()
    for part, model in s.get("models", {}).items():     # "turbo": {...} — для всех моделей с turbo в имени
        if part.lower() in ckpt and name in model:
            return model[name]
    return s.get(name, default)


def build_prompt(prompts: dict, item: Item, style: str) -> tuple[str, str, list[int]]:
    s = prompts.get("settings", {})
    kind = prompts.get("kinds", {}).get(item.kind)
    if kind is None:
        sys.exit("%s: неизвестный вид «%s» (есть: %s)" % (item.key, item.kind, ", ".join(prompts.get("kinds", {}))))
    styles = prompts.get("styles", {})
    if style not in styles:
        sys.exit("Нет стиля «%s» (есть: %s)" % (style, ", ".join(styles)))
    text = str(item.extra.get("prompt", kind["prompt"])).format(style=styles[style], subject=item.subject)
    trigger = str(s.get("trigger", "")).strip()
    if trigger:
        text = trigger + ", " + text
    negative = ", ".join(x for x in (prompts.get("negative", ""), kind.get("negative", ""),
                                     item.extra.get("negative", "")) if x)
    size = [int(v) for v in item.extra.get("size", kind.get("size", [1024, 1024]))]
    return text, negative, size


def workflow(params: dict) -> dict:
    """Схема ComfyUI в формате API: модель (+ LoRA стиля) -> текст -> KSampler -> картинка."""
    model, clip = ["1", 0], ["1", 1]
    wf = {"1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": params["checkpoint"]}}}
    if params.get("lora"):
        wf["2"] = {"class_type": "LoraLoader", "inputs": {
            "model": model, "clip": clip, "lora_name": params["lora"],
            "strength_model": params["lora_strength"], "strength_clip": params["lora_strength"]}}
        model, clip = ["2", 0], ["2", 1]
    w, h = params["size"]
    wf.update({
        "3": {"class_type": "CLIPTextEncode", "inputs": {"clip": clip, "text": params["prompt"]}},
        "4": {"class_type": "CLIPTextEncode", "inputs": {"clip": clip, "text": params["negative"]}},
        "5": {"class_type": "EmptyLatentImage", "inputs": {"width": w, "height": h, "batch_size": 1}},
        "6": {"class_type": "KSampler", "inputs": {
            "model": model, "positive": ["3", 0], "negative": ["4", 0], "latent_image": ["5", 0],
            "seed": params["seed"], "steps": params["steps"], "cfg": params["cfg"],
            "sampler_name": params["sampler"], "scheduler": params["scheduler"], "denoise": 1.0}},
        "7": {"class_type": "VAEDecode", "inputs": {"samples": ["6", 0], "vae": ["1", 2]}},
        "8": {"class_type": "PreviewImage", "inputs": {"images": ["7", 0]}},
    })
    return wf


# --- ComfyUI --------------------------------------------------------------------

class ComfyError(RuntimeError):
    pass


class Comfy:
    def __init__(self, urls: list[str], comfy_dir: str = "", args: list[str] | None = None, log=print,
                 app: str = ""):
        self.urls, self.dir, self.args, self.log, self.app = urls, comfy_dir, list(args or []), log, app
        self.url = ""
        self.proc: subprocess.Popen | None = None
        self.client = uuid.uuid4().hex

    def _req(self, path: str, data: dict | None = None, timeout: float = 30.0, url: str = "") -> bytes:
        body = json.dumps(data).encode("utf-8") if data is not None else None
        req = urllib.request.Request((url or self.url) + path, data=body,
                                     headers={"Content-Type": "application/json"} if body else {})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            raise ComfyError("%s %s: HTTP %d %s" % ("POST" if body else "GET", path, e.code,
                                                    e.read().decode("utf-8", "replace")[:2000])) from None

    def get(self, path: str, timeout: float = 30.0):
        return json.loads(self._req(path, timeout=timeout))

    def _find(self) -> str:
        for u in self.urls:
            try:
                self._req("/system_stats", timeout=3, url=u.rstrip("/"))
                return u.rstrip("/")
            except (OSError, ComfyError):
                continue
        return ""

    def start(self) -> None:
        self.url = self._find()
        if self.url:
            return
        root = Path(self.dir) if self.dir else None
        py = root / "python_embeded" / "python.exe" if root else None
        main = root / "ComfyUI" / "main.py" if root else None
        app = desktop_app(self.app)
        if py and py.exists() and main.exists():
            port = urllib.parse.urlparse(self.urls[0]).port or 8188
            log_file = open(root / "server.log", "ab")
            self.log("Запускаю ComfyUI из %s ..." % root)
            self.proc = subprocess.Popen([str(py), "-s", str(main), "--windows-standalone-build", "--listen",
                                          "127.0.0.1", "--port", str(port)] + self.args, cwd=str(root),
                                         stdout=log_file, stderr=subprocess.STDOUT,
                                         creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            where = str(root / "server.log")
        elif app:
            self.log("Открываю Comfy Desktop: %s ..." % app)
            subprocess.Popen([str(app)], cwd=str(app.parent), creationflags=getattr(subprocess, "DETACHED_PROCESS", 0))
            where = "окно Comfy Desktop"
        else:
            raise ComfyError("ComfyUI не отвечает (%s), и не нашёл ни Comfy Desktop, ни портативную версию в «%s». "
                             "Открой ComfyUI или поправь prompts.json -> settings.comfy_app / comfy_dir"
                             % (", ".join(self.urls), self.dir))
        deadline = time.time() + 300
        while time.time() < deadline:
            if self.proc is not None and self.proc.poll() is not None:
                raise ComfyError("ComfyUI закрылся при запуске, смотри %s" % where)
            self.url = self._find()
            if self.url:
                return
            time.sleep(2)
        raise ComfyError("ComfyUI не запустился за 5 минут, смотри %s" % where)

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(30)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc = None

    def options(self, node: str, field_name: str) -> list[str]:
        spec = self.get("/object_info/" + node).get(node, {}).get("input", {}).get("required", {}).get(field_name)
        if not spec:
            return []
        if isinstance(spec[0], list):                     # старый формат: [[варианты], {...}]
            return [str(v) for v in spec[0]]
        if spec[0] == "COMBO" and len(spec) > 1:          # новый: ["COMBO", {"options": [...]}]
            return [str(v) for v in spec[1].get("options", [])]
        return []

    def render(self, wf: dict, timeout: float = 900.0) -> bytes:
        res = json.loads(self._req("/prompt", {"prompt": wf, "client_id": self.client}))
        if res.get("node_errors"):
            raise ComfyError("ComfyUI не принял схему: %s" % json.dumps(res["node_errors"], ensure_ascii=False)[:2000])
        pid = res["prompt_id"]
        deadline = time.time() + timeout
        while time.time() < deadline:
            hist = self.get("/history/" + pid).get(pid)
            if hist:
                status = hist.get("status", {})
                if status.get("status_str") == "error":
                    msgs = [m[1] for m in status.get("messages", []) if m and m[0] == "execution_error"]
                    detail = msgs[0].get("exception_message", "") if msgs else json.dumps(status)[:1000]
                    raise ComfyError("ошибка генерации: %s" % detail.strip())
                for out in hist.get("outputs", {}).values():
                    for img in out.get("images", []):
                        q = urllib.parse.urlencode({"filename": img["filename"], "subfolder": img.get("subfolder", ""),
                                                    "type": img.get("type", "temp")})
                        return self._req("/view?" + q, timeout=60)
                if status.get("completed"):
                    raise ComfyError("ComfyUI закончил, но картинки нет")
            time.sleep(1)
        raise ComfyError("картинка не готова за %d с" % timeout)


def desktop_app(setting: str) -> Path | None:
    """Программа Comfy Desktop: из настройки или в обычном месте установки."""
    if setting:
        p = Path(os.path.expandvars(setting))
        return p if p.exists() else None
    base = Path(os.environ.get("LOCALAPPDATA", "")) / "Programs"
    if not os.environ.get("LOCALAPPDATA") or not base.exists():
        return None
    for exe in sorted(base.glob("*omfy*/*.exe")):
        if "uninstall" not in exe.name.lower():
            return exe
    return None


def choose_lora(setting: str, available: list[str], log) -> str:
    if setting and setting != "auto":
        if setting not in available:
            raise ComfyError("нет LoRA «%s» в models/loras (есть: %s)" % (setting, ", ".join(available) or "ничего"))
        return setting
    if setting != "auto":
        return ""
    fits = [n for n in available if LORA_HINT.search(n)]
    fits.sort(key=lambda n: (bool(re.search(r"1\.?5|sd15", n, re.I)), n))   # для SDXL — первыми
    if not fits:
        log("  ! LoRA гравюры не нашлась в models/loras, рисую без неё")
        return ""
    return fits[0]


# --- Обработка картинки ---------------------------------------------------------

def make_tileable(img: Image.Image, blend: float = 0.3) -> Image.Image:
    """Бесшовная текстура: края заменяются серединой со сдвигом на полкартинки, переход плавный."""
    a = np.asarray(img.convert("RGB")).astype(np.float32)
    h, w = a.shape[:2]
    rolled = np.roll(a, (h // 2, w // 2), axis=(0, 1))

    def ramp(n):
        x = np.abs(np.arange(n) - (n - 1) / 2) / max(1.0, (n - 1) / 2)   # 0 в середине, 1 у края
        t = np.clip((1.0 - x) / blend, 0.0, 1.0)
        return t * t * (3 - 2 * t)

    wgt = np.minimum.outer(ramp(h), ramp(w))[..., None]
    out = a * wgt + rolled * (1.0 - wgt)
    return Image.fromarray(out.round().clip(0, 255).astype(np.uint8), "RGB")


def alpha_from_black(img: Image.Image) -> Image.Image:
    """Облако на чёрном фоне -> полупрозрачное облако: яркость становится непрозрачностью."""
    a = np.asarray(img.convert("RGB")).astype(np.float32) / 255.0
    alpha = np.clip((a.max(axis=2) - 0.06) / 0.94, 0.0, 1.0)
    rgb = np.where(alpha[..., None] > 1e-3, a / np.maximum(alpha[..., None], 1e-3), 0.0).clip(0, 1)
    out = np.dstack([rgb, alpha]) * 255.0
    return Image.fromarray(out.round().astype(np.uint8), "RGBA")


def postprocess(img: Image.Image, item: Item, prompts: dict) -> Image.Image:
    kind = prompts.get("kinds", {}).get(item.kind, {})
    if kind.get("tileable"):
        img = make_tileable(img)
    if kind.get("alpha_from_black"):
        img = alpha_from_black(img)
    return img


FIGURE_KINDS = {"unit", "object"}


def figure_problems(img: Image.Image) -> list[str]:
    """Что не так с фигурой на однотонном фоне: фон, обрезка краем, отдельно висящий предмет."""
    arr = np.asarray(img.convert("RGBA"))
    if (arr[..., 3] < import_art.ALPHA_MIN).mean() < 0.02:
        arr, removed = import_art.remove_background(arr)
        if not removed:
            return ["фон не убрался"]
    mask = arr[..., 3] >= 128
    if mask.mean() > 0.6:
        return ["фон не убрался"]
    h, w = mask.shape
    k = max(1, max(h, w) // 200)
    small = mask[:h - h % k, :w - w % k].reshape(h // k, k, w // k, k).any(axis=(1, 3))
    sh, sw = small.shape
    seen = np.zeros_like(small)
    sizes = []
    for y0, x0 in zip(*np.nonzero(small)):
        if seen[y0, x0]:
            continue
        seen[y0, x0] = True
        stack, n = [(y0, x0)], 0
        while stack:
            y, x = stack.pop()
            n += 1
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= ny < sh and 0 <= nx < sw and small[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    stack.append((ny, nx))
        sizes.append(n)
    if not sizes:
        return ["пусто"]
    sizes.sort(reverse=True)
    problems = []
    edge = np.concatenate([small[0], small[-1], small[:, 0], small[:, -1]])
    if edge.mean() > 0.02:
        problems.append("обрезано краем")
    if len(sizes) > 1 and sizes[1] >= 0.06 * sizes[0]:
        problems.append("отдельный предмет")
    return problems


# --- Варианты, выбор, листы сравнения -------------------------------------------

def variant_dir(root: Path, item: Item) -> Path:
    return root / "art" / "generated" / item.category / item.out_id


def variants(root: Path, item: Item) -> list[Path]:
    d = variant_dir(root, item)
    return sorted(d.glob("v*.png"), key=lambda p: import_art.natural_key(p.name)) if d.exists() else []


def variant_number(path: Path) -> int:
    m = re.match(r"v(\d+)", path.name)
    return int(m.group(1)) if m else 0


def load_record(path: Path = RECORD) -> dict:
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}


def generate(root: Path, prompts: dict, todo: list[Item], count: int | None, style: str, comfy: Comfy, log=print,
             checkpoint: str = "") -> list[Path]:
    """count — сколько вариантов на картинку (None — из prompts.json: у вида или общее)."""
    s = prompts.get("settings", {})
    comfy.start()
    stats = comfy.get("/system_stats")
    dev = (stats.get("devices") or [{}])[0]
    log("ComfyUI %s, %s, видеопамять %.1f ГБ" % (stats.get("system", {}).get("comfyui_version", "?"),
                                                dev.get("name", "?"), float(dev.get("vram_total", 0)) / 2**30))
    checkpoints = comfy.options("CheckpointLoaderSimple", "ckpt_name")
    checkpoint = checkpoint or str(s.get("checkpoint", ""))
    if checkpoint not in checkpoints:
        raise ComfyError("нет модели «%s» в models/checkpoints (есть: %s)" % (checkpoint, ", ".join(checkpoints) or "ничего"))
    lora = choose_lora(str(s.get("lora", "auto")), comfy.options("LoraLoader", "lora_name"), log)
    log("Модель %s, LoRA %s, стиль %s" % (checkpoint, lora or "нет", style))
    made = []
    for n, item in enumerate(todo, 1):
        prompt, negative, size = build_prompt(prompts, item, style)
        d = variant_dir(root, item)
        d.mkdir(parents=True, exist_ok=True)

        def opt(name, default):
            return setting(prompts, item, name, default, checkpoint)

        want = count or int(opt("variants", 3))
        good, tries, limit = 0, 0, want + (int(opt("retries", 2)) if item.kind in FIGURE_KINDS else 0)
        while tries < want or (good == 0 and tries < limit):
            tries += 1
            seed = random.randint(1, 2**31 - 1)
            params = {"prompt": prompt, "negative": negative, "size": size, "seed": seed, "style": style,
                      "checkpoint": checkpoint, "lora": lora,
                      "lora_strength": float(opt("lora_strength", 0.9)), "steps": int(opt("steps", 25)),
                      "cfg": float(opt("cfg", 6.5)), "sampler": str(opt("sampler", "dpmpp_2m")),
                      "scheduler": str(opt("scheduler", "karras"))}
            t0 = time.time()
            data = comfy.render(workflow(params))
            params["seconds"] = round(time.time() - t0, 1)
            num = max([variant_number(p) for p in variants(root, item)] + [0]) + 1
            path = d / ("v%02d_%s_%d.png" % (num, style, seed))
            img = postprocess(Image.open(io.BytesIO(data)), item, prompts)
            params["problems"] = figure_problems(img) if item.kind in FIGURE_KINDS else []
            good += not params["problems"]
            img.save(path)
            path.with_suffix(".json").write_text(json.dumps(params, ensure_ascii=False, indent=1) + "\n",
                                                  encoding="utf-8")
            made.append(path)
            log("  [%d/%d] %s вариант %d: %.0f с%s" % (n, len(todo), item.key, num, params["seconds"],
                                                      "  ! " + ", ".join(params["problems"]) if params["problems"] else ""))
    return made


def pick(root: Path, item: Item, number: int, record: dict, prompts: dict) -> Path:
    found = [p for p in variants(root, item) if variant_number(p) == number]
    if not found:
        have = ", ".join(str(variant_number(p)) for p in variants(root, item)) or "нет"
        raise SystemExit("%s: нет варианта %d (есть: %s)" % (item.key, number, have))
    src = found[0]
    out_dir = root / "art" / "inbox" / "generated" / item.category
    out_dir.mkdir(parents=True, exist_ok=True)
    dst = out_dir / (item.out_id + ".webp")
    img = Image.open(src)
    img.load()
    img.save(dst, "WEBP", quality=95, method=6)
    hint = {"id": item.out_id, "bind": item.bind, "kind": IMPORT_KIND.get(item.kind, "image"),
            "cols": 1, "rows_count": 1}
    if item.kind in KEEP_BACKGROUND:
        hint["background"] = "keep"
    dst.with_name(item.out_id + ".art.json").write_text(json.dumps(hint, ensure_ascii=False) + "\n", encoding="utf-8")
    params = json.loads(src.with_suffix(".json").read_text(encoding="utf-8")) if src.with_suffix(".json").exists() else {}
    record[item.key] = dict(params, variant=src.name, file=dst.relative_to(root).as_posix())
    return dst


def contact_sheet(root: Path, category: str, items: list[Item], record: dict, prompts: dict) -> Path | None:
    rows = [(it, variants(root, it)[-6:]) for it in items if it.category == category]
    rows = [(it, vs) for it, vs in rows if vs]
    if not rows:
        return None
    names = import_art.display_names(root / "data")
    cell, label_w, pad = 220, 230, 10
    cols = max(len(vs) for _, vs in rows)
    sheet = Image.new("RGB", (label_w + cols * (cell + pad) + pad, len(rows) * (cell + 34) + pad), (40, 40, 46))
    d = ImageDraw.Draw(sheet)
    font, small = import_art._font(18), import_art._font(14)
    for r, (it, vs) in enumerate(rows):
        y = pad + r * (cell + 34)
        title = names.get((it.category, it.gid), it.gid.replace("/", ": "))
        d.text((pad, y + 4), it.gid, fill=(240, 220, 140), font=font)
        d.text((pad, y + 28), title, fill=(200, 200, 210), font=small)
        chosen = record.get(it.key, {}).get("variant")
        if chosen:
            d.text((pad, y + 50), "выбран: %d" % variant_number(Path(chosen)), fill=(120, 220, 120), font=small)
        tile = prompts.get("kinds", {}).get(it.kind, {}).get("tileable")
        for c, v in enumerate(vs):
            x = label_w + c * (cell + pad)
            img = Image.open(v).convert("RGBA")
            if tile:   # бесшовность видно, когда текстура повторена 2×2
                half = img.resize((cell // 2, cell // 2), Image.LANCZOS)
                thumb = Image.new("RGBA", (cell, cell))
                for k in range(4):
                    thumb.paste(half, ((k % 2) * (cell // 2), (k // 2) * (cell // 2)))
            else:
                img.thumbnail((cell, cell), Image.LANCZOS)
                thumb = import_art._checker((cell, cell)).convert("RGBA")
                thumb.alpha_composite(img, ((cell - img.size[0]) // 2, (cell - img.size[1]) // 2))
            sheet.paste(thumb.convert("RGB"), (x, y))
            if chosen == v.name:
                d.rectangle((x - 3, y - 3, x + cell + 2, y + cell + 2), outline=(120, 220, 120), width=3)
            d.text((x + 4, y + cell + 4), str(variant_number(v)), fill=(255, 255, 255), font=font)
            meta = v.with_suffix(".json")
            problems = json.loads(meta.read_text(encoding="utf-8")).get("problems", []) if meta.exists() else []
            if problems:
                d.rectangle((x - 1, y - 1, x + cell, y + cell), outline=(230, 70, 60), width=2)
                d.text((x + 30, y + cell + 7), ", ".join(problems), fill=(240, 110, 100), font=small)
    out = root / "art" / "generated" / (category + ".png")
    sheet.save(out)
    return out


def ensure_ignored(root: Path) -> None:
    gen = root / "art" / "generated"
    gen.mkdir(parents=True, exist_ok=True)
    (gen / ".gdignore").touch()            # Godot не импортирует черновики


def main() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="replace")
        except AttributeError:
            pass
    p = argparse.ArgumentParser(description="Картинки для игры из Stable Diffusion (ComfyUI)")
    p.add_argument("what", nargs="*", help="units/knight, skills, tiles/forest/wall ... (по умолчанию всё)")
    p.add_argument("--more", action="store_true", help="нарисовать ещё варианты, даже если они уже есть")
    p.add_argument("--variants", type=int, help="сколько вариантов на картинку (по умолчанию из prompts.json)")
    p.add_argument("--style", help="стиль из prompts.json -> styles (color, plain ...)")
    p.add_argument("--checkpoint", help="другая модель из models/checkpoints (по умолчанию settings.checkpoint)")
    p.add_argument("--pick", nargs="+", metavar="ID=N", help="выбрать вариант N для игры: units/knight=2")
    p.add_argument("--pick-first", action="store_true", help="сразу выбрать первый новый вариант")
    p.add_argument("--list", action="store_true", help="показать, что описано и что выбрано")
    p.add_argument("--dry-run", action="store_true", help="только показать запросы, ничего не рисовать")
    p.add_argument("--root", default=str(ROOT), help="папка проекта Godot")
    args = p.parse_args()

    root = Path(args.root)
    prompts = load_prompts()
    s = prompts.get("settings", {})
    items = items_of(prompts, root / "data")
    record = load_record()
    style = args.style or str(s.get("style", "color"))

    if args.list:
        for it in items:
            chosen = record.get(it.key, {}).get("variant", "")
            print("%-32s %-8s вариантов: %d%s" % (it.key, it.kind, len(variants(root, it)),
                                                  "  выбран " + chosen if chosen else ""))
        return

    if args.pick:
        by_key = {it.key: it for it in items}
        for spec in args.pick:
            key, _, num = spec.rpartition("=")
            item = by_key.get(key.strip("/")) or next((it for it in items if it.out_id == key or it.gid == key), None)
            if item is None or not num.isdigit():
                sys.exit("Не понял «%s»: нужно так: units/knight=2" % spec)
            print("%s: вариант %s -> %s" % (item.key, num, pick(root, item, int(num), record, prompts).relative_to(root)))
        RECORD.write_text(json.dumps(record, ensure_ascii=False, indent=1, sort_keys=True) + "\n", encoding="utf-8")
        for cat in {by_key[k].category for k in record if k in by_key}:
            contact_sheet(root, cat, items, record, prompts)
        print("Теперь запусти импорт: python tools/art/import_art.py")
        return

    todo = [it for it in select(items, args.what) if args.more or not variants(root, it)]
    count = args.variants
    if args.dry_run:
        total = 0
        for it in todo:
            prompt, negative, size = build_prompt(prompts, it, style)
            n = count or int(setting(prompts, it, "variants", 3, args.checkpoint or ""))
            total += n
            print("%s (%s, %dx%d, %d шт. -> %s)\n  + %s\n  - %s" % (it.key, it.kind, size[0], size[1], n, it.bind,
                                                                   prompt, negative))
        print("Всего: %s, %s" % (import_art.plural(len(todo), "картинка", "картинки", "картинок"),
                                 import_art.plural(total, "вариант", "варианта", "вариантов")))
        return
    if not todo:
        print("Всё уже нарисовано. Ещё варианты: --more, выбор: --pick units/knight=2")
        return

    ensure_ignored(root)
    urls = s.get("comfy_url", ["http://127.0.0.1:8188", "http://127.0.0.1:8000"])
    comfy = Comfy(urls if isinstance(urls, list) else [urls], os.environ.get("COMFYUI_DIR", s.get("comfy_dir", "")),
                  s.get("comfy_args", []), app=str(s.get("comfy_app", "")))
    t0 = time.time()
    try:
        made = generate(root, prompts, todo, count, style, comfy, checkpoint=args.checkpoint or "")
    except ComfyError as e:
        sys.exit("Ошибка: %s" % e)
    except KeyboardInterrupt:
        sys.exit("Остановлено")
    finally:
        comfy.stop()
    if args.pick_first:
        for it in todo:
            new = [v for v in variants(root, it) if v in made]
            if new:
                pick(root, it, variant_number(new[0]), record, prompts)
        RECORD.write_text(json.dumps(record, ensure_ascii=False, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    sheets = [contact_sheet(root, cat, items, record, prompts) for cat in CATEGORIES if any(it.category == cat for it in todo)]
    print("Готово: %d картинок за %.0f мин" % (len(made), (time.time() - t0) / 60))
    for sh in sheets:
        if sh:
            print("  сравнить: %s" % sh.relative_to(root))
    print("Выбрать: python tools/art/generate.py --pick units/knight=2 ...  затем import_art.py")


if __name__ == "__main__":
    main()
