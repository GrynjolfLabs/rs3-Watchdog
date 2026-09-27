"""Generate the Watchdog showreel as editable Tesseract document JSON.

Writes .tesseract-work/showreel.json; commit it with
  tsrct project commit --project Watchdog-showreel.tsrct --file .tesseract-work/showreel.json

Everything is authored in GLOBAL composition milliseconds and converted to each
owner layer's local clock at the end (keyframe layerTime is owner-local, and
nested activeRanges are parent-relative).

Picture is cut to the synthesized 120 BPM bed (beat 500 ms, bar 2000 ms); see
audio-map.json for the cue list. Visual language is Watchdog's own editor theme
(ui/theme.lua): square-cornered node bodies, category-colored headers, white exec
wires, orange selection.

Font family keys: tsrct 0.2.0 registers multi-word families without spaces, so
the packaged "Space Grotesk" / "JetBrains Mono" faces are addressed as
"SpaceGrotesk" / "JetBrainsMono" (verified via renderer debug log).
"""
import json
import math
from pathlib import Path

WORK = Path(__file__).parent
W, H = 1920, 1080
DUR_MS = 26000


# ------------------------------------------------------------------ palette

def c(r, g, b, a=1.0):
    return [round(r / 255, 4), round(g / 255, 4), round(b / 255, 4), a]


BG = c(26, 26, 30)
GRID = c(40, 40, 47)
GRID_MAJOR = c(52, 52, 60)
BODY = c(43, 43, 48, 0.96)
BORDER = c(15, 15, 18)
TRIGGER = c(155, 47, 47)
ACTION = c(47, 95, 155)
FLOW = c(70, 70, 80)
TRIGGER_HI = c(232, 92, 82)
ACTION_HI = c(96, 158, 236)
ORANGE = c(240, 160, 32)
EXEC = c(242, 242, 242)
WHITE = [1, 1, 1, 1]
BLACK = [0, 0, 0, 1]
T_NUMBER = c(63, 159, 111)
T_BOOL = c(150, 47, 47)
T_STRING = c(192, 63, 159)
T_ANY = c(176, 176, 176)
TITLE = c(240, 240, 244)
PIN_LABEL = c(198, 200, 208)
CTRL_BG = c(28, 28, 33)
CTRL_BORDER = c(70, 70, 82)
CTRL_TEXT = c(225, 227, 233)
CTRL_EMPTY = c(120, 122, 132)
TEST_BG = c(46, 78, 52)
TEST_GLYPH = c(200, 240, 205)
TOAST_BG = c(24, 24, 28, 0.92)
TOAST_BORDER = c(10, 10, 12)
TOAST_TEXT = c(230, 230, 236)
FLASH_RED = [1, 0, 0, 0.5]  # Screen Flash node default {255,0,0,127}

DISPLAY = "SpaceGrotesk"
MONO = "JetBrainsMono"


def ease(x1, y1, x2, y2):
    return {"type": "cubicBezier", "x1": x1, "y1": y1, "x2": x2, "y2": y2}


OUT = ease(0.16, 1, 0.3, 1)        # snappy arrival
OUT_SOFT = ease(0.25, 0.8, 0.3, 1)
INOUT = ease(0.65, 0, 0.35, 1)
IN = ease(0.7, 0, 0.84, 0)
BACK = ease(0.34, 1.56, 0.64, 1)   # small overshoot
LIN = {"type": "linear"}
HOLD = {"type": "hold"}


# ------------------------------------------------------------------ document builder

class Doc:
    def __init__(self):
        self._id = 0
        self._item = 1000
        self._kf = 0
        self.anims = []      # (owner_layer_id, target, spec)
        self.item_owner = {}  # effect / selector id -> owning layer id

    def nid(self):
        self._id += 1
        return self._id

    def item(self, owner):
        self._item += 1
        self.item_owner[self._item] = owner
        return self._item

    # ---- animation (global ms) ----
    def keys(self, lid, prop, keys):
        self.anims.append((lid, {"kind": "layer", "layerId": lid, "propertyType": prop}, ("keys", keys)))

    def item_keys(self, item_id, prop, keys):
        owner = self.item_owner[item_id]
        self.anims.append((owner, {"kind": "fxItemProperty", "itemId": item_id, "propertyName": prop}, ("keys", keys)))

    def effect_keys(self, effect_id, param, keys):
        owner = self.item_owner[effect_id]
        self.anims.append((owner, {"kind": "effectProperty", "effectId": effect_id, "paramName": param}, ("keys", keys)))

    def script(self, lid, prop, body):
        """body sees `t` = GLOBAL seconds."""
        self.anims.append((lid, {"kind": "layer", "layerId": lid, "propertyType": prop}, ("js", body)))

    def effect_script(self, effect_id, param, body):
        owner = self.item_owner[effect_id]
        self.anims.append((owner, {"kind": "effectProperty", "effectId": effect_id, "paramName": param}, ("js", body)))

    def scale(self, lid, keys):
        self.keys(lid, "scaleX", keys)
        self.keys(lid, "scaleY", keys)

    def pos(self, lid, keys):
        self.keys(lid, "positionX", [(t, v[0], e) for t, v, e in keys])
        self.keys(lid, "positionY", [(t, v[1], e) for t, v, e in keys])

    # ---- finalize ----
    def resolve(self, layers):
        starts = {}

        def walk(items, base):
            for layer in items:
                s = base + layer["activeRange"]["start"]
                starts[layer["id"]] = s
                if layer.get("layers"):
                    walk(layer["layers"], s)

        walk(layers, 0)
        # One track per target: several helpers may animate the same property.
        merged = {}
        order = []
        for owner, target, spec in self.anims:
            key = json.dumps(target, sort_keys=True)
            if key not in merged:
                merged[key] = (owner, target, spec)
                order.append(key)
                continue
            prev = merged[key]
            if prev[2][0] != "keys" or spec[0] != "keys":
                raise ValueError(f"conflicting script/keyframe tracks on {target}")
            merged[key] = (owner, target, ("keys", prev[2][1] + spec[1]))
        entries = []
        for key in order:
            owner, target, spec = merged[key]
            t0 = starts[owner]
            if spec[0] == "js":
                code = f"var t = input.time.seconds + {t0 / 1000:.4f};\n" + spec[1]
                entries.append({"target": target, "animator": {"type": "jsScript", "layerTimeJsCode": code}})
                continue
            local = sorted(((int(round(t - t0)), v, e) for t, v, e in spec[1]), key=lambda k: k[0])
            # Keys authored before the owner starts collapse onto its first frame (latest wins).
            before = [k for k in local if k[0] < 0]
            local = [k for k in local if k[0] >= 0]
            if before and (not local or local[0][0] > 0):
                local.insert(0, (0, before[-1][1], before[-1][2]))
            kfs = []
            last = None
            for lt, v, e in local:
                if lt == last:
                    if kfs[-1]["value"] != value_of(v):
                        raise ValueError(f"conflicting keys at {lt + t0} on {target}")
                    kfs[-1]["easing"] = e or LIN
                    continue
                last = lt
                self._kf += 1
                kfs.append({"id": f"k{self._kf}", "layerTime": lt, "value": value_of(v), "easing": e or LIN})
            entries.append({"target": target, "animator": {"type": "keyframes", "enabled": True, "keyframes": kfs}})
        return entries


def value_of(v):
    if isinstance(v, str):
        return {"type": "string", "value": v}
    if isinstance(v, (list, tuple)):
        if len(v) == 4:
            return {"type": "color", "value": list(v)}
        return {"type": "vector2", "value": list(v)}
    return {"type": "float", "value": float(v)}


D = Doc()


def rng(start, dur):
    return {"start": int(start), "duration": int(dur)}


def tf(x=0, y=0, ax=0, ay=0, sx=100, sy=None, o=100, r=0, rx=0, ry=0):
    t = {"anchorPoint": [ax, ay], "position": [x, y], "scale": [sx, sx if sy is None else sy],
         "rotation": r, "opacity": o}
    if rx:
        t["rotationX"] = rx
    if ry:
        t["rotationY"] = ry
    return t


def group(name, layers, start, dur, x=0, y=0, ax=0, ay=0, o=100, s=100, masks=None, mblur=False, lid=None,
          effects=None):
    g = {"type": "Group", "id": lid or D.nid(), "name": name, "blendMode": "normal",
         "activeRange": rng(start, dur), "transform": tf(x, y, ax, ay, s, o=o), "layers": layers}
    if masks:
        g["masks"] = masks
    if effects:
        g["effects"] = effects
    if mblur:
        g["motionBlur"] = True
    return g


def rect(name, x, y, w, h, color, start, dur, ax=0, ay=0, o=100, stroke=None, fill=True,
         shadow=None, effects=None, blend="normal", paint=None, mblur=False):
    r = {"size": [w, h], "fillColor": color if fill else [0, 0, 0, 0], "fillEnabled": fill}
    if paint:
        r["fillPaint"] = paint
    if stroke:
        r.update({"strokeEnabled": True, "strokeColor": stroke[0], "strokeWidth": stroke[1], "strokeJoin": "miter"})
    layer = {"type": "Rect", "id": D.nid(), "name": name, "blendMode": blend, "activeRange": rng(start, dur),
             "transform": tf(x, y, ax, ay, o=o), "rect": r}
    if shadow:
        layer["dropShadow"] = {"blendMode": "normal", "color": shadow[0], "offset": shadow[1],
                               "blurRadius": shadow[2], "spreadRadius": 0, "enabled": True}
    if effects:
        layer["effects"] = effects
    if mblur:
        layer["motionBlur"] = True
    return layer


def text(name, s, x, y, size, start, dur, font=DISPLAY, style="Bold", color=WHITE, just="left",
         tracking=0, o=100, animators=None, ax=0, ay=0, sc=100):
    layer = {"type": "Text", "id": D.nid(), "name": name, "blendMode": "normal",
             "activeRange": rng(start, dur), "transform": tf(x, y, ax, ay, sc, o=o),
             "sourceText": {"text": s, "fontFamily": font, "fontStyle": style, "fontSize": size,
                            "fillColor": color, "justification": just, "strokeWidth": 0,
                            "tracking": tracking}}
    if animators:
        layer["animators"] = animators
    return layer


def stroke_style(color, width, cap="round"):
    return {"blendMode": "normal", "cap": cap, "join": "round", "miterLimit": 4, "opacity": 100,
            "paint": {"type": "solid", "color": color}, "width": width}


def fill_style(color):
    return {"blendMode": "normal", "fillRule": "nonZeroWinding", "opacity": 100,
            "paint": {"type": "solid", "color": color}}


def shape(name, commands, start, dur, stroke=None, fill=None, trim=None, x=0, y=0, ax=0, ay=0,
          o=100, effects=None, sc=100, r=0, mblur=False):
    content = {"path": {"commands": commands}, "strokes": [stroke] if stroke else [],
               "fills": [fill] if fill else []}
    if trim is not None:
        content["trim"] = {"start": 0, "end": trim, "mode": "simultaneously"}
    layer = {"type": "Shape", "id": D.nid(), "name": name, "blendMode": "normal",
             "activeRange": rng(start, dur), "transform": tf(x, y, ax, ay, sc, o=o, r=r), "shape": content}
    if effects:
        layer["effects"] = effects
    if mblur:
        layer["motionBlur"] = True
    return layer


def M(x, y):
    return {"type": "moveTo", "x": x, "y": y}


def L(x, y):
    return {"type": "lineTo", "x": x, "y": y}


def C(c1, c2, p):
    return {"type": "cubicTo", "c1x": c1[0], "c1y": c1[1], "c2x": c2[0], "c2y": c2[1], "x": p[0], "y": p[1]}


CLOSE = {"type": "close"}


def poly(points):
    cmds = [M(*points[0])] + [L(*p) for p in points[1:]] + [CLOSE]
    return cmds


def tri_right(cx, cy, s):
    """Exec pin glyph: triangle pointing right, centered at (cx, cy)."""
    h = s / 2
    return poly([(cx - h * 0.8, cy - h), (cx + h, cy), (cx - h * 0.8, cy + h)])


def tri_down(cx, cy, s):
    h = s / 2
    return poly([(cx - h, cy - h * 0.55), (cx + h, cy - h * 0.55), (cx, cy + h * 0.6)])


def diamond(cx, cy, r):
    return poly([(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)])


def glow(radius=24, intensity=1.2, threshold=0.1):
    eid = D._item + 1
    return eid, {"id": eid, "effect": {"type": "glow", "glowIntensity": intensity, "glowRadius": radius,
                                       "glowThreshold": threshold}}


def reveal_selector(width=0.5, based="characters", shape_="rampUp"):
    return {"amount": 1, "basedOn": based, "start": 0, "end": width, "offset": -width, "mode": "add",
            "shape": shape_, "units": "percentage"}


def reveal_text(layer, t0, t1, width=0.5, rise=60, blur=0, based="characters", scale=None, e=OUT):
    """Per-unit reveal: units start offset down by `rise`, transparent; sweep left->right."""
    sel = D.item(layer["id"])
    anim_id = D.item(layer["id"])
    a = {"id": anim_id, "opacity": 0, "position": [0, rise],
         "selectors": [dict(reveal_selector(width, based), id=sel)]}
    if blur:
        a["blur"] = [0, blur]
    if scale:
        a["scale"] = scale
    layer.setdefault("animators", []).append(a)
    D.item_keys(sel, "offset", [(t0, -width, LIN), (t1, 1.0, e)])
    return sel


def bez(p0, c1, c2, p3, u):
    v = 1 - u
    return (v ** 3 * p0[0] + 3 * v * v * u * c1[0] + 3 * v * u * u * c2[0] + u ** 3 * p3[0],
            v ** 3 * p0[1] + 3 * v * v * u * c1[1] + 3 * v * u * u * c2[1] + u ** 3 * p3[1])


def wire_ctrl(a, b):
    dx = max(abs(b[0] - a[0]) * 0.5, 90)
    return (a[0] + dx, a[1]), (b[0] - dx, b[1])


def ease_inout(u):
    return 4 * u ** 3 if u < 0.5 else 1 - (-2 * u + 2) ** 3 / 2


def along(lid, a, b, t0, t1, step=33, offset=(0, 0), easing=ease_inout):
    """Position keys moving a layer along the a->b wire between t0 and t1."""
    c1, c2 = wire_ctrl(a, b)
    keys = []
    n = max(2, int((t1 - t0) / step))
    for i in range(n + 1):
        u = easing(i / n)
        p = bez(a, c1, c2, b, u)
        keys.append((t0 + (t1 - t0) * i / n, (p[0] + offset[0], p[1] + offset[1]), LIN))
    D.pos(lid, keys)


def wire(name, a, b, color, start, dur, t_draw=None, width=5):
    c1, c2 = wire_ctrl(a, b)
    lay = shape(name, [M(*a), C(c1, c2, b)], start, dur, stroke=stroke_style(color, width), trim=100)
    if t_draw:
        D.keys(lay["id"], "trimEnd", [(t_draw[0], 0, LIN), (t_draw[1], 100, INOUT if len(t_draw) < 3 else t_draw[2])])
    return lay


def grid(name, x0, y0, x1, y1, start, dur, minor=48, every=4, col=GRID, col_major=GRID_MAJOR, o=100):
    minor_cmds, major_cmds = [], []
    i = 0
    x = x0
    while x <= x1:
        (major_cmds if i % every == 0 else minor_cmds).extend([M(x, y0), L(x, y1)])
        x += minor
        i += 1
    i = 0
    y = y0
    while y <= y1:
        (major_cmds if i % every == 0 else minor_cmds).extend([M(x0, y), L(x1, y)])
        y += minor
        i += 1
    return group(name, [
        shape(name + " major", major_cmds, 0, dur, stroke=stroke_style(col_major, 2, "butt")),
        shape(name + " minor", minor_cmds, 0, dur, stroke=stroke_style(col, 1.5, "butt")),
    ], start, dur, o=o)


# ------------------------------------------------------------------ editor node

K = 1.6  # video scale of the in-client theme metrics
NW = 250 * K
HH = 26 * K
RH = 24 * K
PT = 8 * K
PB = 10 * K
GLYPH = 12 * K
# tri_right(0, 0, s) centroid (see tri_right); scale pulses use this anchor.
PIN_AX = -0.2 * (GLYPH / 2)
PIN_AY = 0


def node(name, x, y, title, header, left, right, start, dur):
    """Build a Watchdog node body. Returns (group, info) with pin coords in parent space."""
    rows = max(len(left), len(right))
    h = HH + PT + rows * RH + PB
    kids = []
    info = {"x": x, "y": y, "h": h, "pins": {}, "glyphs": {}}

    def cy(r):
        return HH + PT + r * RH + RH / 2

    for r, spec in enumerate(left):
        if spec is None:
            continue
        yy = cy(r)
        lx = 16 + GLYPH / 2 + 10
        kind = spec["kind"]
        if kind in ("exec", "data"):
            if kind == "exec":
                g = shape(f"{title} {spec['label']} pin", tri_right(0, 0, GLYPH), 0, dur,
                          fill=fill_style(EXEC), x=16, y=yy, ax=PIN_AX, ay=PIN_AY)
            else:
                g = rect(f"{title} {spec['label']} pin", 16, yy, GLYPH * 0.8, GLYPH * 0.8, spec["color"],
                         0, dur, ax=GLYPH * 0.4, ay=GLYPH * 0.4)
            kids.append(g)
            info["pins"]["in:" + spec["label"]] = (x + 16, y + yy)
            info["glyphs"]["in:" + spec["label"]] = g["id"]
            if spec.get("test"):
                bx = 16 + GLYPH / 2 + 8
                kids.append(shape("test glyph", tri_right(bx + 13, yy, 10), 0, dur, fill=fill_style(TEST_GLYPH)))
                kids.append(rect("test button", bx, yy - 13, 26, 26, TEST_BG, 0, dur))
                lx = bx + 26 + 10
            kids.append(text(f"{title} {spec['label']} label", spec["label"], lx, yy + 6.5, 18, 0, dur,
                             style="Medium", color=PIN_LABEL))
            ctrl = spec.get("control")
            if ctrl:
                bx = max(lx + len(spec["label"]) * 9.6 + 14, NW * 0.42)
                reserve = 64 if r < len(right) and right[r] else 18
                bw = NW - bx - reserve
                kids.extend(control(ctrl, bx, yy, bw, dur))
        elif kind == "band":
            kids.extend(control(("box", spec["field"]), 16, yy, 214, dur))
            kids.extend(control(("toggle", spec["toggle"]), 238, yy, 96, dur))

    for r, spec in enumerate(right):
        if spec is None:
            continue
        yy = cy(r)
        px = NW - 16
        if spec["kind"] == "exec":
            g = shape(f"{title} {spec['label']} out", tri_right(0, 0, GLYPH), 0, dur,
                      fill=fill_style(EXEC), x=px, y=yy, ax=PIN_AX, ay=PIN_AY)
        else:
            g = rect(f"{title} {spec['label']} out", px, yy, GLYPH * 0.8, GLYPH * 0.8, spec["color"], 0, dur,
                     ax=GLYPH * 0.4, ay=GLYPH * 0.4)
        kids.append(g)
        info["pins"]["out:" + spec["label"]] = (x + px, y + yy)
        info["glyphs"]["out:" + spec["label"]] = g["id"]
        if spec["label"]:
            kids.append(text(f"{title} {spec['label']} out label", spec["label"], px - GLYPH / 2 - 10, yy + 6.5,
                             18, 0, dur, style="Medium", color=PIN_LABEL, just="right"))

    outline = rect(f"{title} selection", -5, -5, NW + 10, h + 10, ORANGE, 0, dur, stroke=(ORANGE, 4),
                   fill=False, o=0)
    kids = [outline] + kids + [
        text(f"{title} title", title, 14, HH / 2 + 8, 22, 0, dur, color=TITLE),
        rect(f"{title} header", 0, 0, NW, HH, header, 0, dur),
        rect(f"{title} body", 0, 0, NW, h, BODY, 0, dur, stroke=(BORDER, 3),
             shadow=([0, 0, 0, 0.55], [0, 12], 28)),
    ]
    g = group(name, kids, start, dur, x=x + NW / 2, y=y + h / 2, ax=NW / 2, ay=h / 2)
    info["id"] = g["id"]
    info["outline"] = outline["id"]
    return g, info


def control(ctrl, bx, yy, bw, dur):
    kind, val = ctrl[0], ctrl[1]
    out = []
    if kind == "swatch":
        out.append(rect("swatch", bx, yy - 13, 74, 26, val, 0, dur, stroke=(CTRL_BORDER, 2)))
        return out
    if kind == "dropdown":
        out.append(shape("caret", tri_down(bx + bw - 13, yy, 10), 0, dur, fill=fill_style(c(170, 172, 182))))
    txt_color = CTRL_EMPTY if kind == "empty" else CTRL_TEXT
    if kind == "toggle":
        out.append(text("toggle", val, bx + bw / 2, yy + 5.5, 15, 0, dur, font=MONO, style="Medium",
                        color=CTRL_TEXT, just="center"))
        out.append(rect("toggle bg", bx, yy - 13, bw, 26, c(52, 56, 66), 0, dur, stroke=(CTRL_BORDER, 2)))
        return out
    out.append(text("ctrl value", val, bx + 8, yy + 5.5, 15, 0, dur, font=MONO, style="Medium", color=txt_color))
    out.append(rect("ctrl box", bx, yy - 13, bw, 26, CTRL_BG, 0, dur, stroke=(CTRL_BORDER, 2)))
    return out


def ex(label="", test=False):
    return {"kind": "exec", "label": label, "test": test}


def da(label, color, control_=None):
    return {"kind": "data", "label": label, "color": color, "control": control_}


def land(info, t, from_y=-50, dur=320):
    """Node landing: drop + scale + fade, arriving on t."""
    gid = info["id"]
    x, y, h = info["x"], info["y"], info["h"]
    D.keys(gid, "opacity", [(t - 120, 0, LIN), (t + 40, 100, OUT)])
    D.keys(gid, "positionY", [(t - 120, y + h / 2 + from_y, LIN), (t + dur - 120, y + h / 2, OUT)])
    D.scale(gid, [(t - 120, 92, LIN), (t + dur - 120, 100, BACK)])


def flash_outline(info, t, hold=180, fade=420):
    D.keys(info["outline"], "opacity", [(t - 1, 0, HOLD), (t, 100, HOLD), (t + hold, 100, LIN), (t + hold + fade, 0, OUT_SOFT)])


def pulse_glyph(lid, t, peak=175):
    D.scale(lid, [(t - 1, 100, LIN), (t + 45, peak, OUT), (t + 260, 100, OUT_SOFT)])


# ------------------------------------------------------------------ eye mark (logo)

def eye_mark(name, cx, cy, s, start, dur, t_in, edge_wires=True, pupil_in=True):
    """Watchdog mark: lids drawn as wires, pupil is a data-pin diamond, exec pins either side."""
    hw, hh = 190 * s, 82 * s
    Lp, Rp = (cx - hw, cy), (cx + hw, cy)
    upper = [M(*Lp), C((cx - hw * 0.45, cy - hh * 1.35), (cx + hw * 0.45, cy - hh * 1.35), Rp)]
    lower = [M(*Lp), C((cx - hw * 0.45, cy + hh * 1.35), (cx + hw * 0.45, cy + hh * 1.35), Rp)]
    lid_w = 12 * s
    ids = {}
    up = shape(f"{name} upper lid", upper, 0, dur, stroke=stroke_style(EXEC, lid_w), trim=0)
    lo = shape(f"{name} lower lid", lower, 0, dur, stroke=stroke_style(EXEC, lid_w), trim=0)
    for lay, d0 in ((up, 0), (lo, 40)):
        D.keys(lay["id"], "trimEnd", [(t_in - 60 + d0, 0, LIN), (t_in + 260 + d0, 100, OUT)])
    ring = shape(f"{name} iris", diamond(0, 0, 58 * s), 0, dur, stroke=stroke_style(EXEC, 4 * s, "butt"),
                 x=cx, y=cy, sc=0)
    D.scale(ring["id"], [(t_in + 60, 0, LIN), (t_in + 380, 100, BACK)])
    geid, g_eff = glow(radius=30 * s, intensity=1.0, threshold=0.2)
    pupil = shape(f"{name} pupil", diamond(0, 0, 34 * s), 0, dur, fill=fill_style(ORANGE), x=cx, y=cy, sc=0,
                  effects=[g_eff], mblur=True)
    D.item_owner[geid] = pupil["id"]
    D._item = max(D._item, geid)
    if pupil_in:
        D.scale(pupil["id"], [(t_in, 0, LIN), (t_in + 300, 100, BACK)])
    kids = [pupil, ring, up, lo]
    pin_l = shape(f"{name} in pin", tri_right(Lp[0] - 34 * s, cy, 26 * s), 0, dur, fill=fill_style(EXEC))
    pin_r = shape(f"{name} out pin", tri_right(Rp[0] + 34 * s, cy, 26 * s), 0, dur, fill=fill_style(EXEC))
    for p, d0 in ((pin_l, 120), (pin_r, 160)):
        D.keys(p["id"], "opacity", [(t_in + d0 - 1, 0, HOLD), (t_in + d0, 100, HOLD)])
    kids += [pin_l, pin_r]
    if edge_wires:
        wl = shape(f"{name} wire in", [M(Lp[0] - 56 * s, cy), L(-40, cy)], 0, dur,
                   stroke=stroke_style(EXEC, 5 * s), trim=0)
        wr = shape(f"{name} wire out", [M(Rp[0] + 56 * s, cy), L(W + 40, cy)], 0, dur,
                   stroke=stroke_style(EXEC, 5 * s), trim=0)
        for lay in (wl, wr):
            D.keys(lay["id"], "trimEnd", [(t_in + 120, 0, LIN), (t_in + 620, 100, OUT)])
        kids += [wl, wr]
    g = group(name, kids, start, dur)
    ids.update(group=g["id"], pupil=pupil["id"], ring=ring["id"], upper=up["id"], lower=lo["id"])
    return g, ids


# ================================================================== SCENES

def scene_hook():
    """0-3750: a feed of real Watchdog trigger events, one per beat, accelerating."""
    S0, SD = 0, 3750
    events = [
        (0, "Inventory", "Backpack full."),
        (500, "Stat Changed", "Level up."),
        (1000, "Player Chat", "Your name in chat."),
        (1500, "Entity Spawn", "Rare spawn."),
        (2000, "Location", "Reached the bank."),
        (2250, "XP Drop", "XP drop."),
        (2500, "Game Message", "Rare drop!"),
        (2750, "Server Tick", "Tick."),
        (3000, "Inventory", "Full again."),
        (3125, "Player Chat", "Clan call."),
        (3250, "Entity Spawn", "Boss up."),
        (3375, "Stat Changed", "99."),
        (3500, "Location", "Arrived."),
        (3625, "Game Message", "Look!"),
    ]
    R = 190
    top = 450
    lines = []
    for i, (te, tag, words) in enumerate(events):
        y0 = i * R
        tag_w = 14 + 18 + 12 + len(tag) * 12.0 + 16
        tag_rect = rect(f"tag {i}", 150, y0, tag_w, 38, TRIGGER, 0, SD)
        tri = shape(f"tag pin {i}", tri_right(150 + 14 + 9, y0 + 19, 18), 0, SD, fill=fill_style(EXEC))
        tag_txt = text(f"tag text {i}", tag, 150 + 14 + 18 + 12, y0 + 26, 20, 0, SD, font=MONO, style="Bold")
        big = text(f"event {i}", words, 146, y0 + 38 + 112, 118, 0, SD, tracking=-10)
        if te > 0:  # the first event is already on screen at frame 0
            D.keys(tag_rect["id"], "scaleX", [(te - 70, 0, LIN), (te + 110, 100, OUT)])
            reveal_text(big, te - 90, te + 160, width=0.35, rise=70, blur=10)
        line = group(f"feed line {i}: {tag}", [tri, tag_txt, tag_rect, big], 0, SD)
        dims = [(te - 91, 0, HOLD), (te - 90, 100, HOLD)]
        for j, lvl in ((1, 42), (2, 20), (3, 9), (4, 0)):
            if i + j < len(events):
                tn = events[i + j][0]
                dims.append((tn + 60, lvl, OUT_SOFT) if tn + 60 > dims[-1][0] else (dims[-1][0] + 1, lvl, OUT_SOFT))
        D.keys(line["id"], "opacity", dims)
        lines.append(line)

    stack = group("feed stack", lines, 0, SD, y=top, mblur=True)
    ys = [(0, top, HOLD)]
    for i, (te, _, _) in enumerate(events[1:], start=1):
        gap = te - events[i - 1][0]
        lead = min(90, gap * 0.45)
        ys.append((te - lead, top - (i - 1) * R, LIN))
        ys.append((te + min(140, gap * 0.6), top - i * R, OUT))
    D.keys(stack["id"], "positionY", ys)

    feed = group("feed (camera)", [stack], 0, SD, x=960, y=540, ax=960, ay=540)
    D.scale(feed["id"], [(0, 100, LIN), (2000, 100, LIN), (3740, 74, IN)])
    D.keys(feed["id"], "rotation", [(2000, 0, LIN), (3740, -4, IN)])

    caption = text("caption", "// while you were AFK", 150, 128, 28, 0, SD, font=MONO, style="Medium",
                   color=PIN_LABEL)
    reveal_text(caption, 0, 420, width=0.08, rise=0, e=LIN)
    caret = text("caret", "_", 150 + 21 * 16.8 + 4, 128, 28, 0, SD, font=MONO, style="Medium", color=ORANGE)
    D.script(caret["id"], "opacity", "return (t % 0.5) < 0.25 ? 100 : 0;")

    counter = text("event counter", "EVENTS 01", W - 150, 128, 26, 0, SD, font=MONO, style="Bold",
                   color=TRIGGER_HI, just="right")
    D.keys(counter["id"], "textContent",
           [(te if te > 0 else 0, f"EVENTS {i + 1:02d}", HOLD) for i, (te, _, _) in enumerate(events)])

    bg_grid = grid("hook grid", -200, -200, 2200, 1500, 0, SD, o=70)
    D.keys(bg_grid["id"], "positionY", [(0, 0, LIN), (3750, -150, LIN)])
    # older lines dissolve before they reach the header row
    fade = {"id": D.item(feed["id"]), "mode": "add", "opacity": 100, "feather": [0, 150], "inverted": False,
            "path": {"commands": poly([(-400, 250), (W + 400, 250), (W + 400, H + 400), (-400, H + 400)])}}
    window = group("feed window", [feed], 0, SD, masks=[fade])
    return group("S1 Hook", [caption, caret, counter, window, bg_grid], S0, SD)


def scene_logo():
    """4000-6000: drop. Eye + wordmark slam; pupil looks around; pupil zooms to fill."""
    S0, SD = 4000, 2000
    t = 4000
    eye, ids = eye_mark("logo eye", 960, 390, 1.0, 0, SD, t, pupil_in=False)
    word = text("wordmark", "WATCHDOG", 960, 705, 196, 0, SD, just="center", tracking=60)
    reveal_text(word, t + 40, t + 480, width=0.4, rise=90, blur=14)
    tag = text("tagline", "visual alerts for RuneScape 3", 960, 790, 34, 0, SD, font=MONO, style="Medium",
               color=PIN_LABEL, just="center")
    reveal_text(tag, t + 900, t + 1300, width=0.06, rise=0, e=LIN)
    for lay in (word, tag):
        D.keys(lay["id"], "opacity", [(5620, 100, LIN), (5800, 0, IN)])
    for key in ("upper", "lower", "ring"):
        D.keys(ids[key], "opacity", [(5620, 100, LIN), (5800, 0, IN)])
    # pupil looks left / right on beats, then zooms to fill the frame (transition)
    pid = ids["pupil"]
    D.keys(pid, "positionX", [(4700, 960, LIN), (4800, 922, OUT), (5200, 922, LIN), (5300, 1000, OUT),
                              (5450, 1000, LIN), (5560, 960, OUT)])
    D.scale(pid, [(4000, 0, LIN), (4300, 100, BACK), (5560, 100, LIN), (5900, 5200, IN)])
    for eg in eye["layers"]:
        if eg["name"].endswith(("pin", "wire in", "wire out")):
            D.keys(eg["id"], "opacity", [(5560, 100, LIN), (5760, 0, IN)])
    lock = group("logo lockup", [eye, word, tag], 0, SD, x=960, y=540, ax=960, ay=540)
    D.scale(lock["id"], [(4000, 116, LIN), (4520, 100, OUT)])
    glow_bg = rect("logo glow", 0, 0, W, H, [0, 0, 0, 0], 0, SD,
                   paint={"type": "gradient", "gradientType": "radial", "start": [960, 430], "end": [1860, 430],
                          "stops": [{"offset": 0, "color": [ORANGE[0], ORANGE[1], ORANGE[2], 0.16]},
                                    {"offset": 1, "color": [ORANGE[0], ORANGE[1], ORANGE[2], 0]}]})
    D.keys(glow_bg["id"], "opacity", [(4000, 0, LIN), (4300, 100, OUT)])
    return group("S2 Logo", [lock, glow_bg], S0, SD)


def scene_editor():
    """6000-14000: the editor. Wire Inventory -> Toast, fire it, zoom out to a bigger graph."""
    S0, SD = 6000, 8000
    nodes, wires, fx = [], [], []

    n1, i1 = node("node Inventory", 150, 300, "Inventory", TRIGGER,
                  [da("Container", T_ANY, ("dropdown", "Inventory"))],
                  [ex(""), da("Used slots", T_NUMBER), da("isFull", T_BOOL), da("Snapshot", T_ANY)], 0, SD)
    n2, i2 = node("node Toast", 1330, 230, "Toast", ACTION,
                  [ex("show", True), ex("dismiss", True), da("text", T_STRING, ("box", "Backpack full!")),
                   da("color", T_ANY, ("swatch", ORANGE)), da("icon", T_ANY, ("empty", "none")),
                   da("sticky", T_BOOL, ("dropdown", "false")), da("hold", T_NUMBER, ("box", "5"))],
                  [], 0, SD)
    n3, i3 = node("node Screen Flash", 1330, 700, "Screen Flash", ACTION,
                  [ex("Show", True), ex("Dismiss", True), da("color", T_ANY, ("swatch", FLASH_RED)),
                   da("In Shape", T_ANY, ("dropdown", "instant")), da("Out Shape", T_ANY, ("dropdown", "instant")),
                   da("Dismiss On", T_ANY, ("dropdown", "both"))], [], 0, SD)
    n4, i4 = node("node Sound Effect", 1330, -60, "Sound Effect", ACTION,
                  [ex("in", True), da("soundId", T_NUMBER, ("box", "3964"))], [], 0, SD)
    n5, i5 = node("node Player Chat", 150, 820, "Player Chat", TRIGGER,
                  [da("type", T_ANY, ("dropdown", "Any")), da("Message contains", T_ANY),
                   {"kind": "band", "field": "zezima", "toggle": "Substring"}, da("Sender contains", T_ANY),
                   {"kind": "band", "field": "", "toggle": "Substring"}],
                  [ex(""), da("message", T_STRING), None, da("sender", T_STRING), None], 0, SD)
    n6, i6 = node("node Popup", 1330, 1100, "Popup", ACTION,
                  [ex("in", True), da("body", T_STRING), da("title", T_STRING, ("box", "Notification")),
                   da("icon", T_ANY, ("empty", "none")), da("theme", T_ANY, ("dropdown", "parchment")),
                   da("hold", T_NUMBER, ("box", "4"))], [], 0, SD)

    out1 = i1["pins"]["out:"]
    show2 = i2["pins"]["in:show"]
    w1 = wire("wire Inventory->Toast", out1, show2, EXEC, 0, SD, t_draw=(7000, 8000))
    w2 = wire("wire Inventory->Sound", out1, i4["pins"]["in:in"], EXEC, 0, SD, t_draw=(10080, 10420))
    w3 = wire("wire Inventory->Flash", out1, i3["pins"]["in:Show"], EXEC, 0, SD, t_draw=(10580, 10920))
    w4 = wire("wire Chat->Popup", i5["pins"]["out:"], i6["pins"]["in:in"], EXEC, 0, SD, t_draw=(11580, 11920))
    w5 = wire("wire message->body", i5["pins"]["out:message"], i6["pins"]["in:body"], T_STRING, 0, SD,
              t_draw=(11640, 12000))
    wires += [w1, w2, w3, w4, w5]

    land(i1, 6000)
    land(i2, 6500)
    land(i4, 10000)
    land(i3, 10500)
    land(i5, 11000)
    land(i6, 11500)

    # connect on the 8000 downbeat
    flash_outline(i2, 8000)
    pulse_glyph(i2["glyphs"]["in:show"], 8000, peak=162)
    # trigger fires at 8500: header flash + pulse along the wire, toast pops at 9000
    flash_outline(i1, 8500, hold=120)
    pulse_glyph(i1["glyphs"]["out:"], 8500, peak=162)
    geid, g_eff = glow(radius=22, intensity=1.4, threshold=0.05)
    pulse = rect("exec pulse", 0, 0, 20, 20, ORANGE, 0, SD, ax=10, ay=10, o=0, effects=[g_eff])
    D.item_owner[geid] = pulse["id"]
    D._item = max(D._item, geid)
    along(pulse["id"], out1, show2, 8500, 9000)
    D.keys(pulse["id"], "opacity", [(8499, 0, HOLD), (8500, 100, HOLD), (9000, 100, LIN), (9080, 0, LIN)])
    flash_outline(i2, 9000, hold=160)
    # 13000: every alert fires at once - pulses down every exec wire
    pulses = []
    for n, (a, b) in enumerate([(out1, show2), (out1, i4["pins"]["in:in"]), (out1, i3["pins"]["in:Show"]),
                                (i5["pins"]["out:"], i6["pins"]["in:in"])]):
        ge, eff = glow(radius=22, intensity=1.4, threshold=0.05)
        p = rect(f"fire pulse {n}", 0, 0, 20, 20, ORANGE, 0, SD, ax=10, ay=10, o=0, effects=[eff])
        D.item_owner[ge] = p["id"]
        D._item = max(D._item, ge)
        along(p["id"], a, b, 13000, 13420)
        D.keys(p["id"], "opacity", [(12999, 0, HOLD), (13000, 100, HOLD), (13420, 100, LIN), (13500, 0, LIN)])
        pulses.append(p)
    for info in (i2, i3, i4, i6):
        flash_outline(info, 13420, hold=200)
    for info in (i1, i5):
        flash_outline(info, 13000, hold=120)

    # cursor dragging the wire 7000-8000, leaving after the connect
    cursor_pts = [(0, 0), (0, 34), (9, 26), (15, 40), (21, 37), (15, 24), (27, 24)]
    cur = shape("cursor", poly(cursor_pts), 0, SD, fill=fill_style(WHITE), stroke=stroke_style(BLACK, 2.5),
                o=0, x=out1[0], y=out1[1])
    along(cur["id"], out1, show2, 7000, 8000, offset=(-2, -2))
    D.keys(cur["id"], "positionX", [(8000, show2[0] - 2, LIN), (8400, show2[0] + 90, OUT)])
    D.keys(cur["id"], "positionY", [(8000, show2[1] - 2, LIN), (8400, show2[1] + 120, OUT)])
    D.keys(cur["id"], "opacity", [(6800, 0, LIN), (6950, 100, OUT), (8150, 100, LIN), (8450, 0, LIN)])

    graph = [cur] + pulses + [pulse] + [n1, n2, n3, n4, n5, n6] + wires
    view_grid = grid("editor grid", -1100, -700, 3000, 1900, 0, SD)
    view = group("editor view", graph + [view_grid], 0, SD, x=960, y=540, ax=960, ay=540)
    D.keys(view["id"], "positionX", [(6000, 960, LIN), (9950, 925, LIN), (10600, 1010, OUT)])
    D.keys(view["id"], "positionY", [(9950, 540, LIN), (10600, 470, OUT), (11900, 470, LIN), (12400, 330, OUT)])
    D.scale(view["id"], [(6000, 104, LIN), (9950, 100, LIN), (10600, 57, OUT), (11900, 56, LIN),
                         (12400, 50, OUT), (14000, 48, LIN)])

    # toast (screen space, top center like the client)
    tw, th = 480, 96
    tx, ty = 960 - tw / 2, 48
    toast = group("toast", [
        text("toast text", "Backpack full!", 6 + 16 + 56 + 16, th / 2 + 10, 30, 0, SD, style="Medium",
             color=TOAST_TEXT),
        {"type": "Image", "id": D.nid(), "name": "toast bell icon", "blendMode": "normal",
         "activeRange": rng(0, SD), "transform": tf(6 + 16 + 28, th / 2, 14, 14, 200),
         "source": {"assetId": "bell", "fit": "contain"}},
        rect("toast accent", 0, 0, 6, th, ORANGE, 0, SD),
        rect("toast bg", 0, 0, tw, th, TOAST_BG, 0, SD, stroke=(TOAST_BORDER, 4),
             shadow=([0, 0, 0, 0.6], [0, 14], 30)),
    ], 0, SD, x=tx + tw / 2, y=ty + th / 2, ax=tw / 2, ay=th / 2, o=0)
    D.keys(toast["id"], "opacity", [(8999, 0, HOLD), (9000, 100, HOLD), (9960, 100, LIN), (10200, 0, LIN)])
    D.keys(toast["id"], "positionY", [(8960, ty + th / 2 - 90, LIN), (9300, ty + th / 2, BACK),
                                      (9960, ty + th / 2, LIN), (10200, ty + th / 2 - 150, IN)])
    D.scale(toast["id"], [(8960, 80, LIN), (9300, 100, BACK)])

    # headline over a bottom scrim at 12000
    scrim = rect("headline scrim", 0, 560, W, 520, [0, 0, 0, 0], 0, SD, o=0,
                 paint={"type": "gradient", "gradientType": "linear", "start": [0, 0], "end": [0, 520],
                        "stops": [{"offset": 0, "color": [0.06, 0.06, 0.07, 0]},
                                  {"offset": 0.55, "color": [0.06, 0.06, 0.07, 0.88]},
                                  {"offset": 1, "color": [0.06, 0.06, 0.07, 0.96]}]})
    D.keys(scrim["id"], "opacity", [(11700, 0, LIN), (12000, 100, OUT)])
    head = text("headline", "Snap triggers to actions.", 120, 905, 104, 0, SD, tracking=-15)
    head["animators"] = [
        {"id": D.item(head["id"]), "fillColor": TRIGGER_HI,
         "selectors": [{"id": D.item(head["id"]), "amount": 1, "basedOn": "characters", "start": 5, "end": 13,
                        "mode": "add", "shape": "square", "units": "index"}]},
        {"id": D.item(head["id"]), "fillColor": ACTION_HI,
         "selectors": [{"id": D.item(head["id"]), "amount": 1, "basedOn": "characters", "start": 17,
                        "end": 24, "mode": "add", "shape": "square", "units": "index"}]},
    ]
    reveal_text(head, 11900, 12380, width=0.5, rise=80, blur=12, based="words")
    sub = text("subline", "no code. just wires.", 126, 975, 34, 0, SD, font=MONO, style="Medium", color=PIN_LABEL)
    reveal_text(sub, 12500, 12900, width=0.06, rise=0, e=LIN)
    return group("S3 Editor", [head, sub, scrim, toast, view], S0, SD)


def scene_reels():
    """14000-19750: WHEN / THEN slot reels, one real trigger->action pair per beat."""
    S0, SD = 13880, 5870
    trig = ["Inventory", "XP Drop", "Player Chat", "Entity Spawn", "Location", "Game Message", "Server Tick",
            "Stat Changed", "Client Tick", "Inventory", "XP Drop", "Player Chat", "Entity Spawn", "Location",
            "Game Message", "Server Tick", "Stat Changed", "Inventory"]
    acts = ["Toast", "Popup", "Sound Effect", "Object Marker", "Screen Marker", "Screen Flash", "InfoBox",
            "Custom Sound", "Alert Toggle", "Log", "Toast", "Popup", "Screen Flash", "Screen Marker",
            "Object Marker", "InfoBox", "Sound Effect", "Toast"]
    steps = [14000 + 500 * k for k in range(8)] + [18000 + 250 * k for k in range(4)] + \
            [19000 + 125 * k for k in range(6)]
    assert len(steps) == len(trig) == len(acts)
    ROW = 150
    BASE = 598

    def reel(side, names, cx, direction):
        items = []
        for k, nm in enumerate(names):
            y = BASE + direction * k * ROW
            items.append(text(f"{side} {k} {nm}", nm, cx, y, 104, 0, SD, just="center", tracking=-10))
        r = group(f"{side} reel", items, 0, SD, y=direction * ROW, mblur=True)
        keys = [(S0, direction * ROW, HOLD)]
        prev = None
        for k, t in enumerate(steps):
            gap = (t - prev) if prev is not None else 500
            lead = min(110, gap * 0.45)
            y_from = -direction * (k - 1) * ROW
            y_to = -direction * k * ROW
            keys.append((t - lead, y_from, LIN))
            keys.append((t + min(90, gap * 0.35), y_to, OUT))
            prev = t
        D.keys(r["id"], "positionY", keys)
        mask = {"id": D.item(r["id"]), "mode": "add", "opacity": 100, "feather": [0, 18], "inverted": False,
                "path": {"commands": poly([(cx - 470, BASE - 118), (cx + 470, BASE - 118),
                                           (cx + 470, BASE + 42), (cx - 470, BASE + 42)])}}
        return group(f"{side} window", [r], 0, SD, masks=[mask])

    left = reel("WHEN", trig, 480, 1)
    right = reel("THEN", acts, 1440, -1)
    lab_l = text("WHEN label", "WHEN", 90, 130, 34, 0, SD, font=MONO, style="Bold", o=85)
    lab_l2 = text("trigger label", "trigger", 90, 172, 24, 0, SD, font=MONO, style="Medium", color=c(255, 210, 205), o=75)
    lab_r = text("THEN label", "THEN", 1050, 130, 34, 0, SD, font=MONO, style="Bold", o=85)
    lab_r2 = text("action label", "action", 1050, 172, 24, 0, SD, font=MONO, style="Medium", color=c(210, 225, 255), o=75)
    pin = shape("center exec pin", tri_right(0, 0, 58), 0, SD, fill=fill_style(EXEC), x=966, y=560)
    scale_keys = []
    for t in steps[:12]:
        scale_keys += [(t - 1, 100, LIN), (t + 50, 138, OUT), (t + 240, 100, OUT_SOFT)]
    D.scale(pin["id"], scale_keys)
    seam_l = shape("seam wire L", [M(900, 560), L(940, 560)], 0, SD, stroke=stroke_style(EXEC, 6))
    seam_r = shape("seam wire R", [M(996, 560), L(1030, 560)], 0, SD, stroke=stroke_style(EXEC, 6))
    foot = text("footer", "any trigger  \u2192  any action", 960, 1000, 30, 0, SD, font=MONO, style="Medium",
                just="center", o=0)
    D.keys(foot["id"], "opacity", [(14400, 0, LIN), (14700, 80, OUT), (17900, 80, LIN), (18100, 0, LIN)])
    panel_l = rect("trigger panel", 0, 0, 960, H, TRIGGER, 0, SD, mblur=True)
    panel_r = rect("action panel", 960, 0, 960, H, ACTION, 0, SD, mblur=True)
    # panels slam in from opposite edges, meeting on the 14000 downbeat
    D.keys(panel_l["id"], "positionY", [(S0, -H, LIN), (14000, 0, IN)])
    D.keys(panel_r["id"], "positionY", [(S0, H, LIN), (14000, 0, IN)])
    texture = grid("reel texture", 0, 0, W, H, 0, SD, col=[0, 0, 0, 0.11], col_major=[0, 0, 0, 0.18], o=100)
    for lay in (lab_l, lab_l2, lab_r, lab_r2, pin, seam_l, seam_r, texture, left, right):
        D.keys(lay["id"], "opacity", [(13999, 0, HOLD), (14000, lay["transform"]["opacity"], HOLD)])
    flash = rect("screen flash (node default color)", 0, 0, W, H, FLASH_RED, 0, SD, o=0)
    D.keys(flash["id"], "opacity", [(16499, 0, HOLD), (16500, 100, HOLD), (16620, 100, LIN), (16950, 0, OUT_SOFT)])
    g = group("S4 Reels", [flash, foot, pin, seam_l, seam_r, left, right, lab_l, lab_l2, lab_r, lab_r2, texture,
                           panel_l, panel_r], S0, SD, x=960, y=540, ax=960, ay=540)
    D.keys(g["id"], "scaleY", [(14000, 100, LIN), (19450, 100, LIN), (19740, 1, IN)])
    D.keys(g["id"], "scaleX", [(14000, 100, LIN), (19450, 100, LIN), (19740, 108, IN)])
    return g


def scene_outro():
    """20000-26000: lockup + mod.io call to action."""
    S0, SD = 20000, 6000
    t = 20000
    eye, ids = eye_mark("outro eye", 960, 300, 0.78, 0, SD, t)
    word = text("outro wordmark", "WATCHDOG", 960, 540, 168, 0, SD, just="center", tracking=60)
    reveal_text(word, t + 20, t + 440, width=0.4, rise=80, blur=12)
    get = text("get it", "Get it on mod.io", 960, 668, 50, 0, SD, style="Medium", just="center")
    reveal_text(get, 20420, 20800, width=0.5, rise=40, blur=6, based="words")
    bw, bh = 900, 80
    bx, by = 960 - bw / 2, 730
    url = text("url", "mod.io/g/runescape/m/watchdog", 960, by + bh / 2 + 14, 40, 0, SD, font=MONO,
               style="Medium", color=CTRL_TEXT, just="center")
    reveal_text(url, 21080, 21700, width=0.04, rise=0, e=LIN)
    box = rect("url box", 960, by + bh / 2, bw, bh, CTRL_BG, 0, SD, ax=bw / 2, ay=bh / 2,
               stroke=(CTRL_BORDER, 3))
    D.keys(box["id"], "scaleX", [(20950, 0, LIN), (21350, 100, OUT)])
    D.keys(box["id"], "opacity", [(20949, 0, HOLD), (20950, 100, HOLD)])
    sel = rect("url selection", 960, by + bh / 2, bw + 12, bh + 12, ORANGE, 0, SD, ax=(bw + 12) / 2,
               ay=(bh + 12) / 2, stroke=(ORANGE, 4), fill=False, o=0)
    D.keys(sel["id"], "opacity", [(21999, 0, HOLD), (22000, 100, HOLD), (22300, 100, LIN), (22800, 55, OUT_SOFT)])
    pin_x = bx - 38
    pin_y = by + bh / 2
    pin_ax = -0.2 * (28 / 2)
    upin = shape("url pin", tri_right(0, 0, 28), 0, SD, fill=fill_style(EXEC), x=pin_x, y=pin_y,
                  ax=pin_ax, ay=0, o=0)
    D.keys(upin["id"], "opacity", [(21299, 0, HOLD), (21300, 100, HOLD)])
    uwire = shape("url wire", [M(-40, pin_y), L(pin_x - 22, pin_y)], 0, SD, stroke=stroke_style(EXEC, 5), trim=0)
    D.keys(uwire["id"], "trimEnd", [(21600, 0, LIN), (22000, 100, INOUT)])
    ge, eff = glow(radius=22, intensity=1.4, threshold=0.05)
    upulse = rect("url pulse", -30, pin_y, 20, 20, ORANGE, 0, SD, ax=10, ay=10, o=0, effects=[eff])
    D.item_owner[ge] = upulse["id"]
    D._item = max(D._item, ge)
    D.keys(upulse["id"], "positionX", [(21600, -30, LIN), (22000, pin_x - 20, INOUT)])
    D.keys(upulse["id"], "opacity", [(21599, 0, HOLD), (21600, 100, HOLD), (22000, 100, LIN), (22100, 0, LIN)])
    pulse_glyph(upin["id"], 22000, peak=145)
    foot = text("outro footer", "RuneScape 3 plugin", 960, 1000, 24, 0, SD, font=MONO, style="Medium",
                color=PIN_LABEL, just="center", o=0)
    D.keys(foot["id"], "opacity", [(21500, 0, LIN), (21900, 70, OUT)])

    pid = ids["pupil"]
    D.keys(pid, "positionX", [(21950, 960, LIN), (22080, 930, OUT), (22450, 930, LIN), (22580, 990, OUT),
                              (22950, 990, LIN), (23080, 960, OUT)])
    eye_blink = ids["group"]
    D.keys(eye_blink, "scaleY", [(23880, 100, LIN), (23960, 8, IN), (24100, 100, OUT)])
    D.keys(eye_blink, "anchorPointY", [(0 + S0, 300, HOLD)])
    D.keys(eye_blink, "positionY", [(0 + S0, 300, HOLD)])

    lock = group("outro lockup", [eye, word, get, url, box, sel, upin, uwire, upulse, foot], 0, SD,
                 x=960, y=540, ax=960, ay=540)
    D.scale(lock["id"], [(20000, 114, LIN), (20520, 100, OUT), (23990, 100, LIN), (24060, 103, OUT),
                         (24400, 100, OUT_SOFT)])
    glow_bg = rect("outro glow", 0, 0, W, H, [0, 0, 0, 0], 0, SD,
                   paint={"type": "gradient", "gradientType": "radial", "start": [960, 380], "end": [1900, 380],
                          "stops": [{"offset": 0, "color": [ORANGE[0], ORANGE[1], ORANGE[2], 0.14]},
                                    {"offset": 1, "color": [ORANGE[0], ORANGE[1], ORANGE[2], 0]}]})
    og = grid("outro grid", -200, -200, 2200, 1500, 0, SD, o=60)
    D.keys(og["id"], "positionY", [(20000, 0, LIN), (26000, -120, LIN)])
    return group("S5 Outro", [lock, glow_bg, og], S0, SD)


# ------------------------------------------------------------------ audio

def audio(name, asset, start, src_dur, gain, dur=None):
    dur = dur or src_dur
    return {"type": "Audio", "id": D.nid(), "name": name, "activeRange": rng(start, dur),
            "sourceRange": rng(0, dur), "sourceIntrinsicDuration": src_dur, "source": {"assetId": asset},
            "volume": gain, "captionsEnabled": False, "windowMs": dur}


def build():
    s1 = scene_hook()
    s2 = scene_logo()
    s3 = scene_editor()
    s4 = scene_reels()
    s5 = scene_outro()

    flash = rect("hit flash", 0, 0, W, H, WHITE, 0, DUR_MS, o=0)
    D.keys(flash["id"], "opacity", [(3999, 0, HOLD), (4000, 80, HOLD), (4280, 0, OUT_SOFT),
                                    (19999, 0, HOLD), (20000, 75, HOLD), (20280, 0, OUT_SOFT)])
    blackout = rect("blackout", 0, 0, W, H, BLACK, 0, DUR_MS, o=0)
    D.keys(blackout["id"], "opacity", [(3749, 0, HOLD), (3750, 100, HOLD), (3999, 100, HOLD), (4000, 0, HOLD),
                                       (19749, 0, HOLD), (19750, 100, HOLD), (19999, 100, HOLD), (20000, 0, HOLD),
                                       (25000, 0, LIN), (26000, 100, LIN)])

    bg = rect("viewport background", 0, 0, W, H, BG, 0, DUR_MS)

    # Finish lives on a group, not an Adjustment layer: in tsrct 0.2.0 a root Adjustment layer
    # lets text draw through the blackout/flash layers above it.
    picture_id = D.nid()
    ca_id = D.item(picture_id)
    grain_id = D.item(picture_id)
    picture = group("picture (finish: chromatic hits + grain)", [s5, s4, s3, s2, s1, bg], 0, DUR_MS,
                    lid=picture_id, effects=[
                        {"id": ca_id, "effect": {"type": "chromaticAberration", "amount": 0, "direction": 0}},
                        {"id": grain_id, "effect": {"type": "grain", "amount": 0.05, "size": 1.2, "softness": 0.5,
                                                    "seed": 3, "aspectRatio": 1}},
                    ])
    hits = [(4000, 1.0), (8000, 0.4), (9000, 0.4), (14000, 0.7), (16500, 0.7), (20000, 1.0)]
    ca = [(0, 0, HOLD)]
    for t, a in hits:
        ca += [(t - 1, 0, HOLD), (t, 0.9 * a, HOLD), (t + 260, 0, OUT_SOFT)]
    D.effect_keys(ca_id, "amount", ca)

    vignette = rect("vignette", 0, 0, W, H, [0, 0, 0, 0], 0, DUR_MS,
                    paint={"type": "gradient", "gradientType": "radial", "start": [960, 540], "end": [2060, 540],
                           "stops": [{"offset": 0, "color": [0, 0, 0, 0]}, {"offset": 0.5, "color": [0, 0, 0, 0]},
                                     {"offset": 1, "color": [0, 0, 0, 0.55]}]})
    sound = [
        audio("music bed (original, 120 BPM)", "music-v4", 0, 26000, 0.75),
        audio("sfx whoosh: pupil zoom", "sfx-whoosh-a", 5657, 500, 0.45),
        audio("sfx click: wire connects", "sfx-connect-click", 8000, 65, 0.55),
        audio("sfx pop: toast", "sfx-toast-pop", 9000, 180, 0.6),
        audio("sfx whoosh: zoom out", "sfx-whoosh-b", 9758, 600, 0.4),
    ]
    layers = [blackout, flash, vignette, picture] + sound
    doc = json.loads((WORK / "editable.json").read_text(encoding="utf-8"))
    doc["dimensions"] = {"width": W, "height": H}
    doc["duration"] = DUR_MS / 1000
    doc["composition"]["layers"] = layers
    doc["composition"]["dynamics"] = {"entries": D.resolve(layers)}
    doc["composition"]["motionBlur"] = {"enabled": True, "shutterAngle": 180, "shutterPhase": -90,
                                        "samplesPerFrame": 12, "adaptiveSampleLimit": 24}
    out = WORK / "showreel.json"
    out.write_text(json.dumps(doc, indent=1), encoding="utf-8", newline="\n")
    print(f"wrote {out} ({len(D.anims)} animation tracks, {D._id} layers)")


if __name__ == "__main__":
    build()
