"""Проверка data/story/*.json: ссылки между диалогами, квестами, предметами, NPC, локациями и флагами.

Запуск из корня проекта: python tools/story/check_story.py
Код выхода 1, если есть ошибки. Предупреждения ошибкой не считаются.
"""
import json
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
STORY = os.path.join(ROOT, "data", "story")

HERO_TEMPLATES = {"knight", "wizard", "ranger", "cleric"}
ATTRIBUTES = {"strength", "dexterity", "intelligence", "constitution", "speed", "perception"}
EFFECT_KEYS = {"set_flag", "quest", "stage", "give_item", "take_item", "count", "to", "xp", "gold", "combat",
               "heal_party", "status", "goto", "spawn", "music", "sfx", "stinger", "shake", "show_npc", "hide_npc",
               "tip", "end_demo"}
COND_KEYS = {"flag", "not_flag", "quest", "stage", "party_min", "hero", "has_item", "gold_min"}

errors = []
warnings = []


def load(name, base=STORY):
    path = os.path.join(base, name)
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        return json.load(f)


dialogues = load("dialogues.json")
quests = load("quests.json")
items = load("items.json")
npcs = load("npcs.json")
enemies = load("enemies.json")
locations = load("locations.json")
characters = load("characters.json", os.path.join(ROOT, "data"))
statuses = load("statuses.json", os.path.join(ROOT, "data")).get("statuses", {})

quest_stages = {q: [s["id"] for s in d["stages"]] for q, d in quests.items()}
encounters = {e["id"]: loc for loc, d in locations.items() for e in d.get("encounters", [])}
flags_set = set()
flags_read = {}


def as_list(v):
    return v if isinstance(v, list) else [v]


def check_cond(cond, where):
    for k in cond:
        if k not in COND_KEYS:
            errors.append(f"{where}: неизвестное условие '{k}'")
    for key in ("flag", "not_flag"):
        for fl in as_list(cond.get(key, [])):
            flags_read.setdefault(fl, where)
    if "quest" in cond:
        q = cond["quest"]
        if q not in quests:
            errors.append(f"{where}: нет квеста '{q}'")
        else:
            for st in as_list(cond.get("stage", [])):
                if st not in quest_stages[q]:
                    errors.append(f"{where}: у квеста '{q}' нет стадии '{st}'")
    if "hero" in cond and cond["hero"] not in HERO_TEMPLATES:
        errors.append(f"{where}: неизвестный герой '{cond['hero']}'")
    if "has_item" in cond and cond["has_item"] not in items:
        errors.append(f"{where}: нет предмета '{cond['has_item']}'")


def check_effects(effects, where):
    for eff in effects:
        for k in eff:
            if k not in EFFECT_KEYS:
                errors.append(f"{where}: неизвестный эффект '{k}'")
        if "set_flag" in eff:
            flags_set.add(eff["set_flag"])
        if "quest" in eff:
            q = eff["quest"]
            if q not in quests:
                errors.append(f"{where}: нет квеста '{q}'")
            elif eff.get("stage") not in quest_stages[q]:
                errors.append(f"{where}: у квеста '{q}' нет стадии '{eff.get('stage')}'")
        for key in ("give_item", "take_item"):
            if key in eff and eff[key] not in items:
                errors.append(f"{where}: нет предмета '{eff[key]}'")
        if "to" in eff and eff["to"] not in HERO_TEMPLATES:
            errors.append(f"{where}: give_item.to должен быть шаблоном героя")
        if "combat" in eff and eff["combat"] not in encounters:
            errors.append(f"{where}: нет встречи '{eff['combat']}'")
        if "goto" in eff and eff["goto"] not in locations:
            errors.append(f"{where}: нет локации '{eff['goto']}'")
        for key in ("show_npc", "hide_npc"):
            if key in eff and eff[key] not in npcs:
                errors.append(f"{where}: нет NPC '{eff[key]}'")
        if "status" in eff and statuses and eff["status"] not in statuses:
            errors.append(f"{where}: нет статуса '{eff['status']}'")


def check_next(nxt, nodes, where):
    for entry in as_list(nxt):
        if isinstance(entry, dict):
            if "if" in entry:
                check_cond(entry["if"], where)
            target = entry.get("id")
        else:
            target = entry
        if target not in nodes:
            errors.append(f"{where}: переход на несуществующий узел '{target}'")


speakers = {"narrator", "hero"} | HERO_TEMPLATES | set(npcs)
for did, dlg in dialogues.items():
    nodes = dlg.get("nodes", {})
    if dlg.get("start") not in nodes:
        errors.append(f"{did}: нет стартового узла '{dlg.get('start')}'")
    for nid, node in nodes.items():
        where = f"{did}.{nid}"
        if "text" in node:
            if node.get("speaker") not in speakers:
                errors.append(f"{where}: неизвестный говорящий '{node.get('speaker')}'")
        elif "next" not in node:
            errors.append(f"{where}: узел без текста и без перехода")
        check_effects(node.get("do", []), where)
        if "next" in node:
            check_next(node["next"], nodes, where)
        for i, ch in enumerate(node.get("choices", [])):
            cwhere = f"{where}[{i}]"
            if "if" in ch:
                check_cond(ch["if"], cwhere)
            check_effects(ch.get("do", []), cwhere)
            if "next" in ch:
                check_next(ch["next"], nodes, cwhere)
            if "check" in ch:
                c = ch["check"]
                if c.get("attr") not in ATTRIBUTES:
                    errors.append(f"{cwhere}: неизвестный атрибут проверки '{c.get('attr')}'")
                if c.get("fail") not in nodes:
                    errors.append(f"{cwhere}: нет узла провала '{c.get('fail')}'")
                if "next" not in ch:
                    errors.append(f"{cwhere}: у проверки нет узла успеха (next)")


def check_dialogue_ref(ref, where):
    for entry in as_list(ref):
        did = entry.get("id") if isinstance(entry, dict) else entry
        if isinstance(entry, dict) and "if" in entry:
            check_cond(entry["if"], where)
        if did not in dialogues:
            errors.append(f"{where}: нет диалога '{did}'")


for nid, n in npcs.items():
    check_dialogue_ref(n.get("dialogue"), f"npc {nid}")
    for entry in as_list(n.get("location")):
        loc = entry.get("id") if isinstance(entry, dict) else entry
        if isinstance(entry, dict) and "if" in entry:
            check_cond(entry["if"], f"npc {nid}.location")
        if loc is not None and loc not in locations:
            errors.append(f"npc {nid}: нет локации '{loc}'")

templates = set(enemies) | set(characters)
for lid, loc in locations.items():
    if "on_enter" in loc:
        check_dialogue_ref(loc["on_enter"], f"loc {lid}.on_enter")
    for obj in loc.get("objects", []):
        check_dialogue_ref(obj["dialogue"], f"loc {lid}.{obj['id']}")
        if "if" in obj:
            check_cond(obj["if"], f"loc {lid}.{obj['id']}")
    for enc in loc.get("encounters", []):
        where = f"loc {lid}.{enc['id']}"
        if "on_defeat" in enc:
            check_dialogue_ref(enc["on_defeat"], where)
        if "if" in enc:
            check_cond(enc["if"], where)
        for e in enc.get("enemies", []):
            if "if" in e:
                check_cond(e["if"], where)
            if e["template"] not in templates:
                warnings.append(f"{where}: шаблон '{e['template']}' не найден в enemies.json и data/characters.json")

for fl, where in sorted(flags_read.items()):
    if fl not in flags_set:
        errors.append(f"{where}: флаг '{fl}' проверяется, но нигде не ставится")
for fl in sorted(flags_set - set(flags_read)):
    warnings.append(f"флаг '{fl}' ставится, но нигде не проверяется (может пригодиться позже)")

for w in dict.fromkeys(warnings):
    print("предупреждение:", w)
for e in errors:
    print("ОШИБКА:", e)
total_nodes = sum(len(d.get("nodes", {})) for d in dialogues.values())
print(f"Диалогов: {len(dialogues)}, узлов: {total_nodes}, квестов: {len(quests)}, предметов: {len(items)}, "
      f"NPC: {len(npcs)}, врагов: {len(enemies)}, локаций: {len(locations)}. Ошибок: {len(errors)}.")
sys.exit(1 if errors else 0)
