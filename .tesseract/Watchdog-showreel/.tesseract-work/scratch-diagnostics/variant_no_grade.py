"""Diagnostic: write showreel.json minus the root adjustment layer, into a scratch project."""
import json
import pathlib

WORK = pathlib.Path(__file__).resolve().parent
doc = json.loads((WORK / "showreel.json").read_text(encoding="utf-8"))
layers = doc["composition"]["layers"]
grade = [l for l in layers if l["type"] == "Adjustment"]
doc["composition"]["layers"] = [l for l in layers if l["type"] != "Adjustment"]
gids = {e["id"] for g in grade for e in g["effects"]}
doc["composition"]["dynamics"]["entries"] = [
    e for e in doc["composition"]["dynamics"]["entries"]
    if not (e["target"].get("kind") == "effectProperty" and e["target"].get("effectId") in gids)]
(WORK / "variant-no-grade.json").write_text(json.dumps(doc, indent=1), encoding="utf-8", newline="\n")
print("removed", len(grade), "adjustment layer(s)")
