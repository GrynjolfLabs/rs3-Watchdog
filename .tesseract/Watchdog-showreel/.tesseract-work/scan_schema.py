"""Inspect the Tesseract schemas: list definitions or dump chosen ones."""
import json
import sys
from pathlib import Path

WORK = Path(__file__).parent


def load(name):
    raw = (WORK / name).read_bytes()
    for enc in ("utf-8-sig", "utf-16"):
        try:
            return json.loads(raw.decode(enc))
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
    raise SystemExit(f"cannot decode {name}")


def brief(node):
    """One-line type summary of a schema node."""
    if not isinstance(node, dict):
        return str(node)
    if "$ref" in node:
        return node["$ref"].split("/")[-1]
    if "const" in node:
        return f"const {node['const']!r}"
    if "enum" in node:
        vals = node["enum"]
        return "enum " + ("|".join(map(str, vals)) if len(vals) < 12 else f"({len(vals)} values)")
    for key in ("anyOf", "oneOf"):
        if key in node:
            return " | ".join(brief(n) for n in node[key])
    t = node.get("type", "?")
    if t == "array":
        if "prefixItems" in node:
            return f"[{len(node['prefixItems'])}x {brief(node['prefixItems'][0])}]"
        return f"array<{brief(node.get('items', {}))}>"
    extra = ""
    if "default" in node:
        extra = f" = {node['default']!r}"
    return f"{t}{extra}"


def compact(defs, name):
    d = defs.get(name)
    if d is None:
        print(f"== {name}: MISSING")
        return
    req = set(d.get("required", []))
    print(f"== {name}" + (f"  ({d.get('description')[:200]})" if d.get("description") else ""))
    for prop, node in d.get("properties", {}).items():
        mark = "*" if prop in req else " "
        desc = node.get("description", "") if isinstance(node, dict) else ""
        print(f"  {mark}{prop}: {brief(node)}" + (f"  -- {desc[:160]}" if desc else ""))
    for key in ("oneOf", "anyOf"):
        if key in d:
            print(f"  {key}: {brief(d)}")


def main():
    which = sys.argv[1]  # doc | action
    schema = load("document.schema.json" if which == "doc" else "action.schema.json")
    defs = schema.get("$defs") or schema.get("definitions") or {}
    if len(sys.argv) == 2:
        print("top-level keys:", list(schema.keys()))
        print(len(defs), "definitions")
        print(", ".join(sorted(defs)))
        return
    for name in sys.argv[2:]:
        if name.startswith("~"):
            needle = name[1:].lower()
            print(f"== defs matching {needle}:", [d for d in defs if needle in d.lower()])
            continue
        if name.startswith("!"):
            print(f"===== {name[1:]}")
            print(json.dumps(defs.get(name[1:]), indent=1)[:6000])
            continue
        compact(defs, name)


if __name__ == "__main__":
    main()
