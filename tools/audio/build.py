"""Сборка всей музыки и звуков игры в assets/audio/*.ogg.

  python3 tools/audio/build.py                 # всё
  python3 tools/audio/build.py funeral bell    # только эти id
  python3 tools/audio/build.py --check         # проверить, что data/audio.json и файлы совпадают

Процедурная музыка собирается в assets/audio/procedural/ (там .gdignore, в игру не попадает) и копируется
в music/ и stingers/, только если у трека в data/audio.json нет "source": "game-music". Такие треки
делает tools/audio/import_tracks.py из готовых записей, и пересборка их не трогает.

Нужно: python3 с numpy, scipy, mido; fluidsynth и банк FluidR3_GM.sf2 (путь в RPG_SOUNDFONT); ffmpeg.
"""

import json
import os
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import dsp  # noqa: E402

ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "assets", "audio")
CONFIG = os.path.join(ROOT, "data", "audio.json")
PROCEDURAL = os.path.join(OUT, "procedural")

# Громкость по разделам (RMS, дБ полной шкалы). Тонкая подстройка — volume_db в data/audio.json.
TARGET = {"music": -18.0, "stingers": -16.0, "ambient": -24.0, "sfx": -15.0, "ui": -19.0}
QUALITY = {"music": 3, "stingers": 5, "ambient": 3, "sfx": 5, "ui": 5}


def build_music(names):
    from musiclib import render_song
    from songs import MUSIC, STINGERS

    cfg = json.load(open(CONFIG, encoding="utf-8"))
    os.makedirs(PROCEDURAL, exist_ok=True)
    open(os.path.join(PROCEDURAL, ".gdignore"), "a").close()
    done = []
    for table, folder, section in ((MUSIC, "music", "music"), (STINGERS, "stingers", "stingers")):
        for name, fn in table.items():
            if names and name not in names:
                continue
            t0 = time.time()
            song, end, loop = fn()
            audio = render_song(song, end, loop=loop, target_db=TARGET[section],
                                tail_sec=6.0 if loop else 5.0)
            path = os.path.join(PROCEDURAL, folder, f"{name}.ogg")
            dsp.save_ogg(path, audio, QUALITY[section])
            done.append(path)
            note = ""
            if cfg[section].get(name, {}).get("source") == "game-music":
                note = "  (в игре запись из game-music)"
            else:
                shutil.copyfile(path, os.path.join(OUT, folder, f"{name}.ogg"))
            print(f"  {folder}/{name}.ogg  {len(audio) / dsp.SR:5.1f} с  {time.time() - t0:4.1f} с сборки{note}")
    return done


def build_sfx(names):
    import sfx

    done = []
    for name, (kind, fn) in sfx.ALL.items():
        if names and name not in names and name.rsplit("_", 1)[0] not in names:
            continue
        t0 = time.time()
        audio = fn()
        folder = "ambient" if kind == "ambient" else "sfx"
        loop = kind == "ambient"
        audio = dsp.master(audio, target_db=TARGET[kind], loop=loop)
        path = os.path.join(OUT, folder, f"{name}.ogg")
        dsp.save_ogg(path, audio, QUALITY[kind])
        done.append(path)
        print(f"  {folder}/{name}.ogg  {len(audio) / dsp.SR:5.2f} с  {time.time() - t0:4.1f} с сборки")
    return done


def check():
    """Все файлы из audio.json существуют, все файлы в assets/audio упомянуты в audio.json."""
    cfg = json.load(open(CONFIG, encoding="utf-8"))
    root = cfg["root"].replace("res://", "")
    referenced = set()
    problems = []
    for section in ("music", "stingers", "ambient", "sfx"):
        for key, entry in cfg[section].items():
            files = list(entry.get("files", [])) + ([entry["file"]] if "file" in entry else [])
            if not files:
                problems.append(f"{section}/{key}: нет файлов")
            for f in files:
                referenced.add(os.path.normpath(os.path.join(ROOT, root, f)))
    for path in sorted(referenced):
        if not os.path.exists(path):
            problems.append(f"нет файла {os.path.relpath(path, ROOT)}")
    for dirpath, dirs, files in os.walk(OUT):
        if ".gdignore" in files:  # папки, которые Godot не импортирует: исходники и запасные версии
            dirs.clear()
            continue
        for f in files:
            p = os.path.normpath(os.path.join(dirpath, f))
            if f.endswith(".ogg") and p not in referenced:
                problems.append(f"файл не упомянут в audio.json: {os.path.relpath(p, ROOT)}")
    sfx_ids = set(cfg["sfx"])
    for alias, target in cfg.get("aliases", {}).items():
        if not any(target in cfg[s] for s in ("music", "stingers", "ambient", "sfx")):
            problems.append(f"алиас {alias} -> {target}: такого id нет")
    for skill, phases in cfg.get("skills", {}).items():
        for phase, sid in phases.items():
            if sid not in sfx_ids:
                problems.append(f"skills.{skill}.{phase} = {sid}: нет такого звука")
    for section in ("statuses", "surfaces"):
        for key, sid in cfg.get(section, {}).items():
            if sid not in sfx_ids:
                problems.append(f"{section}.{key} = {sid}: нет такого звука")
    for p in problems:
        print("  !", p)
    total = sum(os.path.getsize(p) for p in referenced if os.path.exists(p))
    print(f"Файлов: {len(referenced)}, размер {total / 1e6:.1f} МБ, проблем: {len(problems)}")
    return not problems


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--check" in sys.argv:
        sys.exit(0 if check() else 1)
    names = set(args)
    if "--sfx" not in sys.argv:
        build_music(names)
    if "--music" not in sys.argv:
        build_sfx(names)
    if not names:
        check()


if __name__ == "__main__":
    main()
