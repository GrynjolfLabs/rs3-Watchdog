"""Scratch test of wire formats before the real build (writes mech.json)."""
import json
from pathlib import Path

W = Path(__file__).parent
doc = json.loads((W / "editable.json").read_text(encoding="utf-8"))
doc["dimensions"] = {"width": 1920, "height": 1080}
doc["duration"] = 2.0

T = lambda x=0, y=0, ax=0, ay=0, s=100, o=100, r=0: {
    "anchorPoint": [ax, ay], "position": [x, y], "scale": [s, s], "rotation": r, "opacity": o}
AR = {"start": 0, "duration": 2000}


def stroke(color, width):
    return {"blendMode": "normal", "cap": "round", "join": "round", "miterLimit": 4, "opacity": 100,
            "paint": {"type": "solid", "color": color}, "width": width}


layers = [
    # text with a per-character reveal selector
    {"type": "Text", "id": 1, "name": "Reveal text", "blendMode": "normal", "activeRange": AR,
     "transform": T(960, 300),
     "sourceText": {"text": "WATCHDOG", "fontFamily": "SpaceGrotesk", "fontStyle": "Bold",
                    "fontSize": 160, "fillColor": [1, 1, 1, 1], "justification": "center", "strokeWidth": 0},
     "animators": [{"id": 101, "position": [0, 120], "opacity": 0,
                    "selectors": [{"id": 102, "amount": 1, "basedOn": "characters", "start": 0, "end": 1,
                                   "offset": 0, "mode": "add", "shape": "rampUp", "units": "percentage"}]}]},
    # bezier wire with trim
    {"type": "Shape", "id": 2, "name": "Wire", "blendMode": "normal", "activeRange": AR, "transform": T(),
     "shape": {"path": {"commands": [{"type": "moveTo", "x": 200, "y": 700},
                                     {"type": "cubicTo", "c1x": 600, "c1y": 700, "c2x": 700, "c2y": 950, "x": 1100, "y": 950}]},
               "strokes": [stroke([1, 1, 1, 1], 8)], "fills": [],
               "trim": {"start": 0, "end": 0, "mode": "simultaneously"}}},
    # rect: where is its origin?  anchor 0,0 at 1300,600, size 200x100
    {"type": "Rect", "id": 3, "name": "Rect probe", "blendMode": "normal", "activeRange": AR,
     "transform": {**T(1300, 600), "rotationY": 0},
     "rect": {"size": [200, 100], "fillColor": [0.94, 0.63, 0.13, 1]},
     "effects": [{"id": 301, "effect": {"type": "glow", "glowIntensity": 1, "glowRadius": 30, "glowThreshold": 0.2}}]},
    # marker dot at 1300,600 to reveal rect origin
    {"type": "Rect", "id": 4, "name": "Origin dot", "blendMode": "normal", "activeRange": AR,
     "transform": T(1300, 600, 5, 5), "rect": {"size": [10, 10], "fillColor": [1, 0, 0, 1]}},
    # track matte test: text 5 revealed through rect 6 (matte above)
    {"type": "Rect", "id": 6, "name": "Matte", "blendMode": "normal", "activeRange": AR, "transform": T(200, 450),
     "rect": {"size": [400, 150], "fillColor": [1, 1, 1, 1]}},
    {"type": "Text", "id": 5, "name": "Matted", "blendMode": "normal", "activeRange": AR, "transform": T(150, 560),
     "sourceText": {"text": "MATTE MATTE MATTE", "fontFamily": "JetBrainsMono", "fontStyle": "Bold",
                    "fontSize": 80, "fillColor": [0.3, 0.6, 1, 1], "justification": "left", "strokeWidth": 0},
     "trackMatte": {"layer": 6, "mode": "alpha"}},
    {"type": "Rect", "id": 9, "name": "BG", "blendMode": "normal", "activeRange": AR, "transform": T(),
     "rect": {"size": [1920, 1080], "fillColor": [0.102, 0.102, 0.118, 1]}},
]


def kf(i, t, v, kind="float", ease=None):
    return {"id": i, "layerTime": t, "value": {"type": kind, "value": v},
            "easing": ease or {"type": "cubicBezier", "x1": 0.2, "y1": 0, "x2": 0, "y2": 1}}


entries = [
    {"target": {"kind": "fxItemProperty", "itemId": 102, "propertyName": "offset"},
     "animator": {"type": "keyframes", "enabled": True, "keyframes": [kf("sel-a", 0, -1), kf("sel-b", 1000, 1)]}},
    {"target": {"kind": "layer", "layerId": 2, "propertyType": "trimEnd"},
     "animator": {"type": "keyframes", "enabled": True, "keyframes": [kf("trim-a", 0, 0), kf("trim-b", 1000, 100)]}},
    {"target": {"kind": "layer", "layerId": 3, "propertyType": "rotationY"},
     "animator": {"type": "jsScript", "layerTimeJsCode": "return input.time.seconds * 60;"}},
    {"target": {"kind": "effectProperty", "effectId": 301, "paramName": "glowRadius"},
     "animator": {"type": "jsScript", "layerTimeJsCode": "return 5 + input.time.seconds * 40;"}},
]
doc["composition"]["layers"] = layers
doc["composition"]["dynamics"] = {"entries": entries}
(W / "mech.json").write_text(json.dumps(doc, indent=1), encoding="utf-8")
print("ok")
