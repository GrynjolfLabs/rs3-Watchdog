# Deferred: Alert Manager row drag (#92) polish

**Status:** parked 2026-07-31 on branch `wip/drag-rows`. Sort-of working in-client; finicky
gesture start, row ghost sits far below the cursor, drop targeting still wrong. Do not burn
more cycles until a dedicated pass.

**Issue:** [#92](https://github.com/adamk33n3r/rs3-Watchdog/issues/92) (reorder / nest / move-to-scope).
**Code:** `ui/manager.lua` (probe key `watchdog_drag_probe` in PersistentDB), Store move APIs already on main via the #92 merge.

---

## What the client actually does (measured)

PersistentDB probe on Jagex client (`PluginData.db` → `watchdog_drag_probe`):

1. **`dragConfig` must be mutated, never replaced.** Assigning a plain Lua table is ignored.
   Mutate fields on the existing userdata (same pattern as `cursorConfig.mouseOverCursor = …`).

2. **`draggedComponent` is required** for native drag to arm at all. Without it, wiring runs
   (`type(dragConfig) == "userdata"`) but `ONDRAG` never fires. With it set, `ONDRAG` /
   `ONDRAGCOMPLETE` fire.

3. **Native Component drag is horizontal-only here** (inventory / bank style).
   `ONDRAGCOMPLETE` args are `(self, dragDestination, dragEndX, dragEndY)` where **`dragEndX`
   changes with the gesture and `dragEndY` is always `0`**. Fighting layout (Layer tree, row
   Layers, grip as Layer sibling) does **not** unlock Y. Do not expect vertical free drag from
   `dragConfig` alone.

4. **`Mouse.GetPosition()` works** for live cursor (screen space). Prefer it over COMPLETE’s
   `endY` (always 0) and over treating `endY == 0` as “valid”.

5. **Drop Y must use screen-space tree origin.** Mixing screen mouse with parent-local
   `treePanel.y` makes `localY` huge → `ResolveDropTarget` always picks the last row (“everything
   drops to the bottom”). Use PrettyUI `Tooltip.getContext(comp).position(comp)` (see
   `componentScreenPos` in `ui/manager.lua` / Watchdog coordinate-model notes).

6. **Current workaround on `wip/drag-rows`:** keep native drag for gesture begin/end; set
   `renderBehaviour = INVISIBLE` to hide the X-only ghost; drive row Y in `Manager:Update` from
   `Mouse.GetPosition()`. Still finicky (dead-zone / delay, Y offset below cursor, drop math).

---

## Approaches tried (dead or partial)

| Approach | Result |
|----------|--------|
| Plain-table `dragConfig = { … }` | Silent no-op; no `ONDRAG` |
| Mutate delay/deadZone/overlay only | Still no `ONDRAG` until `draggedComponent` set |
| `draggedComponent = rowPanel`, grip inside horizontal `Panel` | Drag arms; ghost X-only |
| Tree as `ui.Layer` + absolute rows | Does not unlock Y |
| Grip as Layer sibling of row | Still X-only; only changes min X of handle |
| Row as `ui.Layer` (no `isVertical=false`) | Still X-only |
| Manual ONCLICK → expand-to-fill → ONRELEASE | Gesture works; early version always dropped to bottom (bad Y); abandoned mid-debug for native path |
| Native + Update-driven Y + screen treeTop | Closest; still offset ghost + unreliable drops |

Related prior art (vertical / free drag elsewhere in this repo family):

- LibUIToolkit window drag / Watchdog graph capture: **ONCLICK + full-screen capture + Logic poll**,
  *not* `dragConfig` (see `.memory/libuitoolkit-window-drag.md`, `.memory/ui-panel-hooks-hover-based.md`).
- Toast / screen-marker capture: same press→poll→release family.

---

## Recommended next pass (when resumed)

1. **Pick one gesture model and delete the hybrid.** Either:
   - **A.** Manual grip: ONCLICK on `::` → expand capture over content (or mux Overlay) →
     Logic-poll mouse → ONRELEASE/ONDRAGCOMPLETE on *same* down-target → drop via
     `Mouse.GetPosition()` + screen `treeTop`. Proven pattern for 2D; matches list reorder UX.
   - **B.** Keep native horizontal drag only for something that is actually horizontal; don’t
     use it for a vertical tree.

2. **Fix the Y offset** once: on drag start, record `grabDY = mouseY - rowScreenTop` (or
   tree-local row Y); each tick `rowY = mouseY - treeTop - grabDY` (not `mouseY - treeTop - ROW_H/2`
   unless that’s intentional).

3. **Dead-zone / delay:** native `dragDelayTicks` / `deadZone` feel finicky on a small `::`
   grip. Manual path can use a clearer threshold or a larger grip hit target.

4. **Drop targeting:** unit tests already cover `ResolveDropTarget`; in-client failures were
   coordinate-frame bugs. After screen `treeTop` is correct, re-verify reorder / nest / inactive
   tab with the probe (keep `watchdog_drag_probe` until green, then remove).

5. **Remove probe** (`dragProbe` / `watchdog_drag_probe`) before merge once behaviour is trusted.

6. **Visual affordance:** prototype uses `⠿`; RS font may not have it (`::` used). Optional
   drop-line highlight still open per #92.

---

## Probe cheat-sheet

```text
Key: watchdog_drag_probe  (PluginID Watchdog)
DB:  C:\ProgramData\Jagex\RuneScape-BETA\PluginData.db   (or Steam sibling)
Copy DB to temp before sqlite read; strip trailing NUL on strings.
```

Helper used during this pass: `.scratch/read_drag_probe.py` (untracked; recreate if missing).
