"""Перерисовать деревню в data/locations.json: python3 write_village.py (из папки tools/maps).
village2.py — сама деревня (дома, река, мост, тропы); village.py — прежняя версия, из неё берутся обстановка домов
и общие таблицы; canvas.py — холст и проверка, что до каждой двери и жителя можно дойти.
После правок домов — перерисовать их рисунки: tools/art/buildings.py и tools/art/import_art.py."""
import json
import os
import village2
from canvas import check

P = os.path.join(os.path.dirname(__file__), "..", "..", "data", "locations.json")
L = json.load(open(P, encoding="utf-8"))
v = L["village"]
v["rows"] = village2.build()
v["legend"] = village2.LEGEND
v["style"]["path"] = ["#76643f", "#685838"]
problems, reach = check("village", v["rows"], village2.LEGEND, (3, int(round(village2.road_y(3)))))
assert not problems, problems
open(P, "w", encoding="utf-8").write(json.dumps(L, ensure_ascii=False, indent=2) + "\n")
print("деревня записана:", len(v["rows"][0]), "x", len(v["rows"]), "клеток, доступно", reach)
