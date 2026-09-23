# Watchdog (UI)

The graph-editor UI for Watchdog: an in-client, Unreal-Blueprints-style visual editor
that renders and manipulates a live `LibNodeGraph` Graph. This context owns only
*presentation and interaction* — the graph model, node types, and execution belong to
[LibNodeGraph](../LibNodeGraph/CONTEXT.md). Watchdog UI never invents graph structure; it
draws what the engine holds and calls back into the engine to mutate it.

The editor is drawn entirely on a single `ui.Canvas` in immediate mode (rebuilt each
`Event.Draw` frame), because Canvas is the only client primitive whose coordinates the
plugin fully controls — a prerequisite for pan and zoom.

## Language

**Editor**:
The Watchdog graph-editor as a whole: the Canvas, its View, the input Capture Layer, and
the interaction logic that binds them to a Graph.
_Avoid_: Blueprint editor, canvas (the Canvas is one part of it), window

**Viewport**:
The on-screen region the Editor draws into — the pannable, zoomable window onto the Graph.
_Avoid_: Canvas (that is the render primitive), pane, frame

**View**:
The transform mapping Graph-space to Screen-space: a pan offset and a zoom factor. Default
is pan at the origin and zoom 1. Applied when drawing, inverted when hit-testing. UI-only
state the engine has no concept of. Wheel zoom walks a shared lattice: `0.25`, every
`1.0 * 1.1^k` strictly inside `(0.25, 2.0)`, and `2.0`.
_Avoid_: Camera, transform (in prose), matrix, scroll

**Reset View**:
Returning the View to that default (origin pan, zoom 1). Distinct from changing zoom alone.
_Avoid_: Reset zoom, fit to view, home, camera reset

**Graph-space**:
The coordinate space Node positions are stored and reasoned about in, independent of pan
and zoom. Distinct from Screen-space, the pixel coordinates the Canvas draws in.
_Avoid_: World space, model space, canvas space

**Layout**:
The UI-owned mapping from a Node's id to its Graph-space position. The engine deliberately
stores no positions, so the Editor owns Layout. Persisted alongside the graph (see Store) as
part of a saved graph, keyed by node id — which round-trips only because the engine now
preserves node ids across serialize/deserialize.
_Avoid_: Positions (as a concept name), coordinates, placement, arrangement

**Store**:
Watchdog's persistence backend (`store.lua`): saves and restores alerts via `PersistentDB`.
LibNodeGraph never persists (it owns only tables/strings, ADR-0007); the Store is the consumer
half. It bundles the engine's serialized structure with the UI-only Layout into each alert
**Entry** and writes a whole Scope's **Entry** tree as one JSON string under its **Bucket** key
(see the Alert Manager section). The `global` Bucket + Entry tree landed in #86; the persisted
`current` pointer is gone — the Editor now constructs unbound and the Manager binds it to an alert
on open (#80/#90), so a reload lands on the Manager. Every Store operation keys on the Entry `id`,
never name. Bucket I/O is key-parametrized: `Store.Load`/`Store.Save` are the `global` shorthands
over `Store.LoadKey(key)` / `Store.SaveTo(key, doc)`, and `Store.PlayerKey(displayName)` builds a
character Bucket's `player_<normalized>` key (#89). Only `Store.Load` runs the one-shot legacy
migration — a character Bucket has no legacy predecessor.
_(Landed: per-character `player_<…>` Buckets (#89), the one-shot legacy `watchdog_graphs` migration
(#87), the read-only Alert Manager render + Editor↔Manager navigation (#90), Manager row
editing ops — create / rename / delete / enable (#91), multi-select / bulk actions (#93),
export/import copy-paste with the 2,500-byte guard (#94), and sibling ↑↓ + Lift buttons.
Not yet landed: drag nest / cross-scope (#92).)_
_Avoid_: Database, save system, persistence layer (in prose), serializer (that's the engine's)

**Capture Layer**:
A single full-screen, visually-empty interactive component sitting over the Canvas whose
sole job is to receive raw pointer events (`ONDRAG`, `ONSCROLLWHEEL`, `ONCLICK`,
`ONRELEASE`) the Canvas cannot, since Canvas drawables are inert. All hit-testing against
Nodes, Pins, and Wires is done manually from `Mouse.GetPosition()`.
_Avoid_: Overlay, hit layer, glass pane, input catcher

**Node Body**:
The filled rectangle drawn for a Node, carrying its Header and Pin rows. Square-cornered
(Canvas has no rounded rectangle).
_Avoid_: Box, card, frame, panel

**Header**:
The category-colored band at the top of a Node Body showing its title. Its color is keyed
off the Node Type's Category.
_Avoid_: Title bar, caption, banner

**Mode**:
A named pin-set on a Node Type (LibNodeGraph ADR-0011). A live Node stores `mode` as instance
metadata — not a Pin and not a Control. LibNodeGraph's Control glossary still says every
editable field is a Control; Watchdog's editor is the exception: the header Mode strip is a
dropdown that calls `Graph:SetMode`, which reconstructs the Node's pin list in place. Shown
only when `GetNodeType(typeKey).modes` is set. Do not name this `Editor.mode` — that field
is the input state machine (`idle` / `pan` / …).
_Avoid_: Variant, preset, Control (the strip is not a Control), Pin

**Pin Glyph**:
The clickable mark drawn for a Pin: a triangle for an Execution Pin (matching Blueprints'
exec shape), a small filled square/diamond for a Data Pin, tinted by its Type Tag color.
The Glyph's Screen-space rectangle is the hit-target for starting or ending a Wire.
_Avoid_: Dot, knob, socket art, handle

**Wire**:
The rendered connection line, drawn as a tessellated bezier S-curve (Canvas has no native
curve). Covers both a committed engine Connection and the *pending* Wire dragged from a Pin
toward the cursor before it commits. Colored by the source Data Pin's Type Tag, or a neutral
color for Execution. NOTE: this softens LibNodeGraph's "avoid wire" rule by design — Wire is
the UI-layer rendering; the engine's model object remains a Connection.
_Avoid_: Line, edge, link (for the model — that stays "Connection")

**Type Color**:
The Editor's mapping from an engine Type Tag (opaque string, e.g. "bool", "coord") to a
draw color for Data Pin Glyphs and their Wires. Owned by the Editor, since the engine is
deliberately tag-agnostic; Execution Pins/Wires use a fixed neutral color outside this map.
_Avoid_: Pin color, tag color (in prose); "palette" (that word names the Palette below)

**Palette**:
The plugin-drawn popup for creating Nodes: a scrollable list of the Registry's Node Types
grouped by Category, drawn on the Editor's Canvas and hit-tested manually like everything
else. Deliberately NOT the native RuneScape MiniMenu, which cannot be extended (ADR-0003).
Modal while open. Opened filtered (Drag-to-Create) or unfiltered (double-click empty
Viewport / the toolbar +). Double-click places the new Node's origin at the click; toolbar +
places the Node Body's center at the Viewport center (#96). Named after Unreal Blueprints'
palette.
_Avoid_: Catalog, menu, context menu, MiniMenu, node browser

**Drag-to-Create**:
Creating a Node by dragging a Wire off a Pin and releasing it on empty Viewport: opens the
Palette filtered to Node Types with a Pin that can receive the Wire (walking every Mode's
pin-set, not just the type default), creates the Node in the matching Mode when needed, and
auto-connects the chosen Node's matching Pin. The typed, one-gesture creation path (as opposed
to the unfiltered double-click / toolbar-+ path).
_Avoid_: Pull-to-create, drag-off, quick-connect

**Control Box**:
The small value box the Editor draws on an unconnected data-input Pin's row, showing that
Pin's Control (the engine's stored value for the Pin). It is Canvas-drawn like everything
else and scales with zoom; connecting the Pin replaces it with a Wire (ADR-0004). Clicking
it opens the Control Editor.
_Avoid_: Field, input box, widget (that's the mounted Editor), textbox

**Compare**:
A Node that compares two values and produces a boolean Result. Its Operation Control
selects equality, inequality, greater than, less than, greater or equal, or less or equal.
Changing the Operation leaves the two input Pins and their Wires in place.
_Avoid_: Separate comparison types. Existing saved alerts can still use the old types.

**Control Editor**:
The single transient real component (`ui.InputField` for text/number, `ui.ComboField` for
an enum) mounted over a Control Box while the user edits it, committing through
`Graph:SetControl` and torn down on commit. The one place the editor uses a real interactive
component rather than a Canvas drawable — deliberately short-lived so its inability to
scale/clip with the View doesn't matter (ADR-0004).
_Avoid_: Inline editor, popup, input widget (in prose)

**Control Spec**:
_(Target model: this passive table dissolves into the active **Pin Control** module below — the
per-Type-Tag behavior is being re-homed so one control's layout, click behavior, and binding stop
living in three files. The description here is the current state until that refactor lands.)_
The Watchdog-owned mapping (`ui/controls.lua`) from an engine Type Tag to how its Control is
rendered and edited: a widget kind (`number` / `text` / `enum` / `composite` / `swatch`) plus,
for an enum, its choices, for a composite, its `extraH`/`Layout` (see Control Band), or for a
swatch, its hex8 `format`/`parse` (see Swatch Chip). Parallel to Type Color, and for the same
reason — the engine is deliberately tag-agnostic, so presentation lives here (ADR-0004). Tags
with no spec (coord, any) get no Control Editor.
_Avoid_: Type metadata, schema, control config

**Widget** _(target model, not yet built)_:
A generic, engine-agnostic input primitive — text field, number field, dropdown, swatch, button,
mode toggle. Draws itself at a rect and edits a value, reporting the edited value back out; knows
nothing of Pins, Nodes, or the Graph. The reusable half, isolated for a possible future UI-library
extraction, so it may depend only on Theme/Color/`ui.*` — never on a Pin Control, the Editor, the
Store, or the engine. Lives under `ui/widgets/`, one file per Widget.
_Avoid_: control, component (that's the client's), field/box (those name one Widget kind, not the concept), Dialog (PrettyUI overlay chrome, not a Canvas primitive)

**Pin Control** _(target model, not yet built)_:
The per-Type-Tag module that composes Widgets and binds them to a Pin's stored Control value (the
location Pin Control lays out three number Widgets + a grab-position button over a `coordgrid`; the
color Pin Control, one swatch Widget). Owns its own layout, internal hit-routing, display, click
behavior, and — crucially — the engine binding: the read-modify-write / codec mapping between a
Widget's natural value and the Pin's stored value, so the matcher's `mode` survives a needle edit.
Reaches the few Editor-only capabilities it needs (mount a transient field, open the Color Popup,
arm a capture, commit) through a passed **host** seam, whose test adapter is a fake host driving
press→commit headless. Replaces the passive Control Spec; registered by Type Tag in `ui/controls.lua`,
one module per control under `ui/controls/`.
_Avoid_: control spec (the passive table it replaces), widget (that's the primitive it composes), handler

**Control Band**:
A `composite`-widget Control's own full-width strip drawn below its Pin's row instead of the
narrow value-column Control Box scalars get (e.g. `coordgrid`'s x/z/level fields + "set to
current position" button). Its height is reserved by the Spec's `extraH`, which pushes every
later Pin row down (Node Body layout is a cumulative running offset, not a fixed
`PIN_ROW_HEIGHT` stride, for exactly this reason); its contents come from the Spec's
`Layout`, one or more Control Boxes sharing the Pin's name and discriminated by a `kind`
("field" for an editable sub-value, "action" for a one-shot button like "set to current
position"). Reserved always; drawn/hit-tested only above `CONTROL_MIN_ZOOM`, same as any
Control Box.
_Avoid_: Sub-panel, composite box, field group

**Matcher**:
A reusable text-match specification carried by a Data Pin (Type Tag `matcher`): a needle
string plus a Mode — **Substring** (case-insensitive, literal) or **Pattern** (case-sensitive,
Lua pattern with magic characters). An empty needle matches everything (the filter is a
no-op). Rendered as a Control Band holding a text field and a single-row Mode toggle after
it; its matching semantics are shared by every Node that filters text (chat message, chat
sender, entity name, …) rather than reimplemented per Node.
_Avoid_: Filter, search, query, "contains" (as the concept name)

**Swatch Chip**:
A `swatch`-widget Control's on-Pin box (e.g. `color`'s `{r,g,b,a}` table): a checker-backed
color-filled rect in the same value column a scalar Control Box occupies, discriminated by
`kind == "swatch"` in `geom.controls` the way a Control Band's sub-rects are discriminated by
`kind`. Unlike every other Control kind, clicking it does not mount a Control Editor — it
opens the Color Popup instead.
_Avoid_: Color box, preview, control box (that's the scalar/composite kind)

**Color Popup**:
The Canvas-drawn, click-to-open picker for a `swatch` Control (`ui/color_popup.lua`): an
SV field + hue strip (drag), a hex8 field (the Control Spec's `format`/`parse`, mounted as a
transient real `ui.InputField` exactly like a Control Editor), and R/G/B/A drag rows. Modal
like the Palette — drawn on the same editor-chrome Canvas, in the same fixed screen-space,
clamped inside the Viewport, and dismissed by an outside click / Esc / re-click / its own ✕ —
but unlike the Palette its SV/hue/channel rows are themselves draggable, not single-shot
picks. Deliberately transient editor state, not part of any Node's `geom.controls`.
_Avoid_: Color picker dialog (Dialog is PrettyUI overlay chrome; this is Canvas), swatch popup, panel (in prose — that's the Palette's own word)

**Test Button**:
A small ▶ button drawn between an exec-in Pin's glyph and its label (`geom.testButtons`, one
per exec-in Pin, gated on `CONTROL_MIN_ZOOM` like a Control Box). Clicking it fires that exec
input directly through the engine (`Graph:FireInput`), running the Node's `run` as if a wire
had fired into that Pin — a live fire whose real side effects happen, for testing a Node in
isolation without wiring a Trigger.
_Avoid_: Run button, play button, trigger button

## Alert Manager

The management surface for **multiple** saved alerts and their player scoping — the layer above
the single-alert Editor. Window chrome uses PrettyUI (`prettyui.Window` via the Multiplexer);
content is a **hybrid**: PrettyUI for scope tabs and form controls, native `ui.Panel` rows for
the tree strip (ADR-0007) — see [`docs/alert-manager-prettyui.md`](docs/alert-manager-prettyui.md).
Not the Editor's Canvas. Row **name** is a labeled PrettyUI SimpleButton; row **actions** and
reorder are PrettyUI SpriteButtons (pencil / export / trash, arrows). Destructive delete goes
through a **Confirm dialog**, not a two-click armed label. This vocabulary was settled across
the Alert Manager wayfinder map (#73); each term points at the ticket that fixed it.

**Alert Manager**:
The single management surface the F8 keybind and the LibPluginMenu button open (`ui/manager.lua`):
a **tab bar** of Scopes over a tree of Entries. “All characters” and the character tab explain
scope through tooltips. Clicking an alert name opens the Editor; clicking a group expands it.
Rows have centered enable/select checkboxes, left-aligned names, and rename/export/delete actions.
Move exposes sibling reorder (↑↓) and Lift controls; Move and bulk selection are mutually exclusive.
Selected entries swap Move/Import/Export on the same toolbar row: Clear (n), Group, Move to the other scope, Export, and Delete.
The two surfaces are mounted once, with at most one visible at a time (#76, #78, #80).

The Editor toolbar sits on the native title strip as icon buttons (Back, Rename, Add node,
zoom, Reset view) with labels in tooltips. The window title shows the alert name.
The Viewport is the full content rect. Native title-drag re-fronts the overlay each frame
so header icons, Maximize, and the resize grip stay on the window. PrettyUI's fullscreen
title capture stays in front for the gesture so leaving the header does not drop the window.
Dialogs parent to the mux root layer. The native title bar remains
draggable; a bottom-right grip resizes the window and Maximize/Restore (square title icon)
preserves its prior bounds.
The tree/scope/expand/mutation logic is headless-tested; mocked UI checks cover layout and input
stacking, while actual appearance and client event delivery still require in-game verification.
_Avoid_: Alert list, manager window, dashboard; the Editor (that is the Canvas graph surface)

**Dialog**:
Watchdog overlay chrome: a centered PrettyUI Window with a caller-filled body, footer actions,
and a modal dim by default. A footer action can dismiss it or leave it open; an action with no
click handler dismisses. Titlebar X fires `onDismiss()` (optional, no args) and pops — it is not a generic
close hook and does not also run an action `onClick`. Footer actions left-to-right in table order,
last is primary (rightmost), group at the bottom-right. Dialogs on one parent Layer **stack**: mount
pushes, dismiss pops; one visual dim for the stack; a blocker under the top Dialog so buried Dialogs
stay mounted and inert. Not dismissed by Esc — the client would also open the pause menu. Distinct
from Palette and Color Popup (Canvas editor chrome) and from Widget (Canvas input primitives).
_Avoid_: Window (the PrettyUI primitive it wraps), transfer, popup, Widget, onClose (that's PrettyUI's)

**Confirm dialog**:
A Dialog preconfigured as a yes/no ask: Cancel (neutral) and a confirm FancyButton (positive by
default). Callers see `onConfirm` and `onCancel` only — titlebar X is Cancel (`onDismiss` →
`onCancel`); the Cancel button is an action `onClick` → `onCancel`. Title, body, confirm label, and
confirm variant are the caller's. Delete copy belongs to the Manager (trash / bulk delete), not to
Confirm.
_Avoid_: modal, popup, two-click delete, armed delete, OK N?, treating Confirm as the delete UI, onClose

**Entry**:
A node in a Scope's persisted tree — `kind = "alert" | "group"` — carrying a minted `id`. Identity
is the `id`; **names carry no uniqueness constraint**, so every operation keys on `id`, never name.
Ordering is array position within its parent's `children` (#75).
_Avoid_: Item, record, row (that is an Entry's on-screen rendering); "graph entry" (legacy Store term)

**Lift**:
Reparenting an Entry one level toward the root: it leaves its parent Group and becomes a sibling of
that Group (a root Entry if the parent was itself a root), inserted immediately before the former
parent. Distinct from reordering among siblings (Up / Down). The reverse — nesting one level deeper —
is not part of this vocabulary yet (drag nest stays on #92).
_Avoid_: Promote, outdent, move out, unnest, demote

**Alert**:
A leaf Entry (`kind = "alert"`) bundling one saved graph with its Layout and an `enabled` flag —
the unit the Editor opens and the runtime fires (#75).
_Avoid_: Graph (that is the engine model an Alert wraps), rule, trigger

**Group**:
A branch Entry (`kind = "group"`) with a `children` array of Entries (alerts and/or nested groups).
Its `enabled` is an **inheritable master switch**: a disabled Group silences its whole subtree, so
an Alert fires iff its own `enabled` AND every ancestor Group's `enabled` are true — the
**enabled-chain** (#75).
_Avoid_: Folder, category, section; "group" as a verb (that is bulk New-group, #82)

**Bucket**:
The per-Scope `PersistentDB` key holding one Scope's tree as `{ version, entries }`: one `global`
bucket plus one `player_<normalized>` bucket per character. The `global` bucket also holds
`infoboxAnchor` (the former `current` pointer is no longer persisted — see Level, #80). Keys carry
**no `watchdog_` prefix** — `PersistentDB` is already plugin-scoped (#81). Scope is the Bucket, not
a per-Entry field: changing an Entry's Scope moves its subtree across keys (#75, #77, #81).
_Avoid_: Store slot, namespace, table; "partition" (that names the concept — see Scope)

**Scope**:
The partition a Bucket represents: `global`, or a single character keyed on `displayName`. Not a
field on an Entry — an Entry's Scope is simply which Bucket holds it (#75, #77).
_Avoid_: Profile, player field, owner, context

**Active scope**:
The Scope new Entries land in — the Manager's currently-selected tab; `global` when logged out. The
selector offers **`global` + the current character only** (#77, #78).
_Avoid_: Selected scope, focus; "current scope" (that word names the deleted Store pointer)

**Armed** / **Resident**:
Two independent runtime states of a loaded Bucket (landed in `runtime.lua`, #89). **Resident** =
loaded in memory. **Armed** = eligible to fire: `global` is armed at plugin start and never
disarmed; a character Bucket arms on the `GAME` transition when its `displayName` is unchanged (a
world-hop/reconnect re-arms *in place* — no reload, so `pollEdgeState` and `pollSeedKey` survive and no `Enter` is
replayed), disarms but stays resident on leaving `GAME`, and is discarded+reloaded only on a
genuine character switch (a rename, having no stable account id, reads as a switch and orphans the
old Bucket). Identity has no switch event, so it's resolved by a **pending-resolve flag drained on
Logic ticks** (which also covers a plugin reload mid-session). **Fire predicate: armed Bucket AND
enabled-chain true — nothing else** (editor state and the Manager's selected Scope never gate
firing) (#77, #89).
_Avoid_: Active / loaded (ambiguous between the two states), enabled (that is the per-Entry switch)

**Level** / **bound entry**:
The depth-1 navigation stack between Manager (root) and Editor. The **bound entry** is the `id` the
Editor is currently bound to via `BindEntry` — **transient, never persisted** (it replaced the old
persisted `current`, so a reload always lands on the Manager) (#80).
_Avoid_: Current (the deleted persisted pointer), page, breadcrumb, depth

**Selection**:
The per-tab set of checked Entries a bulk action operates on. **Group-as-unit** and normalized to an
**antichain** — checking a Group represents its whole subtree, no descendant is separately selected
(so no tri-state checkbox) — over the visible flattened row order. Cleared when the visible list is
replaced (scope switch, collapse); preserved across export and hide/show (#82).
_Avoid_: Checked set, marked rows; "multi-select" (that names the gesture, not the resulting set)

**Import / Export dialog**:
A Dialog wrapper with two recipes: **Import** (paste a JSON envelope) and **Export** (copy one
out). Envelope is `{ schemaVersion, pluginVersion, entries }`; there is no clipboard API, and
save-to-file is designed but disabled until a filesystem API exists (#79) — Export still shows that
dead footer action. Import is **append, never merge-by-name**. The wrapper does not import: it asks
the caller to apply the pasted text. A failed apply leaves Import mounted and stacks a message
Dialog on top (closing the error reveals the paste field intact). A successful apply just dismisses
Import — no success notice; the Manager tree is the feedback. Every export shape (whole scope,
single row, multi-select) passes a uniform **2,500-byte pre-flight guard**: serialize the envelope,
measure its UTF-8 byte length, and refuse the entire export — exporting nothing — if it exceeds
2,500 (the `InputField` hard cap, #83); no chunking or compaction (#84). Export preflight failure
is a message Dialog and never opens Export.
_Avoid_: Transfer; Backup; "sync" (import is append, not sync); clipboard (no API); "serialize"
(engine's word); Export / Import (Import comes first); an Import-success Dialog

## Node domain

**Hold**:
The lifetime in seconds of a non-sticky visual effect before it auto-expires. A sticky effect
ignores Hold and remains until dismissed. Shared pin name and semantics across Toast, Popup
(Popup's Hold is the full-opacity middle of its in/out ramp), Screen Marker, and Object Marker.
_Avoid_: TTL, duration, timeout (as the pin/prose name)

**Screen Marker** (`action.screen_marker`):
An Action that draws a screen-space rectangle outline on the always-on overlay. Authored by a
Capture Arm drag ("Draw on screen"); shown via `show`, cleared via `dismiss` or (when non-sticky)
when Hold elapses. Defaults match Toast (`sticky=false`, `hold=5`).
_Avoid_: overlay box, screen rect, snipping region (those name the capture gesture, not the effect)

**Object Marker** (`action.object_marker`):
An Action that draws a world-anchored tile mark (optional name label) on the always-on overlay,
re-projected every frame from a Capture-Arm Select Object of a Loc. Same Hold/sticky lifetime as Toast;
Tile is the only feasible draw mode on the current API.
_Avoid_: ground marker, tile marker (as the node name); "object" alone (ambiguous with game objs)

**Capture Banner**:
A top-of-screen instruction strip shown while a Screen or Object Marker capture is waiting for
input (drag a region / Select Object on a Loc). Non-interactive — cancel is Esc or re-click of the same
Capture Control. Screen Marker also dims the screen behind it (Snipping-Tool hole while dragging).
Object Marker select additionally hides the Watchdog window (and its overlay capture) so Loc MiniMenu
hover is not covered; Esc or F8 cancels and brings the window back. The shell is restored on a
successful Select Object. If Watchdog was already F8-hidden, it stays hidden.
_Avoid_: toast, notification, armed banner, overlay prompt

**Chat Trigger**:
A Trigger Node that fires on the client's `ChatMessage` event. There are two, split by who
authored the line: the **Game Message** trigger (system/engine/broadcast/examine lines) and
the **Player Chat** trigger (lines a player typed — public, private, friends/clan/group).
Each strips formatting tags from the incoming line before matching, so a Matcher never sees
`<col=…>` markup, and exposes only the Chat Type Groups relevant to it.
_Avoid_: Chat node, message node, chat listener

**Chat Type Group**:
A Watchdog-curated, named grouping of raw engine `ChatType` ids exposed as one choice in a
Chat Trigger's type dropdown (e.g. *Examine* = `OBJ_EXAMINE`/`NPC_EXAMINE`/`LOC_EXAMINE`;
*Private (Received)* = the incoming private + quickchat ids). Deliberately **not** 1:1 with
the client's `ChatType` enum — a simplified, useful vocabulary that hides noise types and
folds quick-chat into its parent channel. A Chat Trigger exposes only its own Groups, and
**Any** means the union of that Trigger's Groups, never the whole enum.
_Avoid_: Chat category, chat kind, chat class; "chat type" (that is the raw engine `ChatType`)

**Container**:
Which client inventory an Inventory Trigger watches. v1 is two engine `InvType`s, labeled
**Inventory** (`Inv.INV`, the backpack) and **Bank** (`Inv.BANK`) — not the rest of the `Inv`
enum. The backpack label is the same word as the Trigger; that collision is accepted. Live
Controls hold the `InvType` userdata; persist/share stores `InvType.id` (JSON cannot encode
proxy types) and decode maps the id back onto `config.Inv.INV` / `config.Inv.BANK`.
_Avoid_: InvType (that is the raw engine config); bag; Backpack (rejected as the Control label)

**Inventory Trigger**:
A Trigger Node that Fires on the client's `InventoryUpdated` event for one Container. One
pin-set, no Modes, no Matcher — item identity is not this Trigger's job. It republishes
occupancy (previous and current used slot counts, whether the Container is full or empty)
and the previous and current Inventory Snapshot. `InventoryAdded` / `InventoryRemoved` do
not Fire this Trigger (they only affect whether a Container is present to snapshot). The
backpack is usually already present, so it may never get `InventoryAdded`; present Containers
are also frozen into that cache at plugin load and on Logic while the cache entry is empty.
_Avoid_: Inventory node; query; RuneLite-style full/empty/count/amount/changed Modes;
a Matcher on this Trigger; Firing on Added/Removed

**Inventory Snapshot**:
The contents of one Container at one moment (previous or current relative to an `InventoryUpdated`, including the cache seeded by
`InventoryAdded`, plugin load, or Logic while a Container is already Find-able). A frozen copy
(not a live `Inv` handle) on a Data Pin with Type Tag `invSnapshot`. `slots` is dense and
1-based: `slots[i]` is client slot `i` (`Inv:GetSlot`), length `slotCount`, empty is `nil`.
An occupied slot freezes `objId`, display `name`, `configName` (Note Filter), and `count`.
Consumed by Item Count, Item Count Changed, and Inventory Viewer.
_Avoid_: packed occupied-only lists; treating `slots[1]` as "first item"; live `Inv`;
inventory, bag, slotDiff (diffs are not a Pin)

**Inventory Viewer**:
An Action in the inventory Category: Execution in, no Execution out. When reached it latches
the wired Inventory Snapshot in Node State (runtime-only; Editor reads it via
`Graph:GetState`). The Editor shows that latch as a PrettyUI ItemGrid overlaid on the Node
Body in screen space: 4 columns × 7 visible rows, a window over `slotCount` (wheel rebinds
those 28 slots). Empty 4×7 chrome until the first latch. Node Body Graph-space height tracks
that screen rectangle each frame. Debugger only — not occupancy, not matching, not a live bag.
_Avoid_: Probe; putting associated-object icons on the Canvas; a full-height ItemGrid of every
Bank slot; Inventory Trigger; naming this the Inventory node (collision with the Trigger is
accepted for the displayName)

**Note Filter**:
A three-way enum on Item Count and Item Count Changed: **Noted**, **Unnoted**, or **Both**
(default Both = no-op). AND'd with the Matcher. Notedness is `ObjType.configName` starting
with `CERT_` — noted and unnoted pairs share the same display `name`, so the Matcher cannot
tell them apart. Authors never see ids or the `CERT_` prefix.
_Avoid_: isNoted, note mode, treating display name as the noted bit; exposing `CERT_` as a Control

**Item Count**:
A Pure Node in the inventory Category: one Inventory Snapshot plus a Matcher plus a Note
Filter in, one number out — the sum of matching slot quantities. Walks `1..slotCount` and
skips empty slots; Lua `#slots` is not the walk (holes). Empty Matcher needle still means
every name; occupancy (used slots) stays on the Inventory Trigger. Threshold crossing is
Compare on Item Count Changed's `count` / `prevCount` (or two Item Counts), not a pin on
this node.
_Avoid_: query node; GetTotal; amount Mode; putting ids on a Control

**Item Count Changed**:
An execution node in the inventory Category: Inventory `out` plus previous and current
Inventory Snapshots, the same Matcher and Note Filter as Item Count. Always publishes
`count`, `prevCount`, and signed `delta`; Fires `changed` only when those two sums differ.
Empty needle means the Container's total stack quantity moved, not that a slot identity swapped.
Previous count comes from the Trigger's frozen prev Snapshot, not `ctx.state`. Thresholds
and "gained only" stay Compare/Branch on the published numbers.
_Avoid_: Matcher on the Inventory Trigger; amount Mode; `unchanged` exec out; remembering
last-count in node state; per-slot identity tracking

**Webhook** (`action.webhook`):
An Action Node that POSTs a JSON body to an HTTP endpoint when exec'd. The endpoint is a
**Base** (chosen from the manifest's `Plugin.urls` allowlist — the client refuses any URL not
declared at build time) plus a **Path**; the node is POST-only. Its body is a JSON template
carrying **Injection Tokens**, and it is the graph's first **async** node — it does not
complete inside the firing sweep but continues later, from the HTTP completion callback.
_Avoid_: HTTP node, request node, "URL node" (the URL is not free-form — see Base);
GET/PUT/DELETE (the node is POST-only and the API only exposes Get/Post)

**Base** (webhook):
The allowlisted host a Webhook targets, selected from the keys of `Plugin.urls` (declared in
`plugin.json`). The client only permits requests to bases declared in the manifest, so a
Webhook can reach any *path* under an allowlisted host but can never invent a new host without
a redeploy. This is a hard client constraint, not a Watchdog choice.
_Avoid_: URL, endpoint (those include the Path); domain

**Injection Token**:
A `{{N}}` placeholder in a Webhook's body template (`{{1}}`, `{{2}}`, `{{3}}`) that is replaced
at send time by the value wired into the node's positional data-input pin `N`. Because the
body is JSON-first, injected values are **JSON-escaped** before substitution, so arbitrary text
(a chat line with quotes or newlines) can't break the payload. The token set is fixed at three
because the engine has no dynamic pins.
_Avoid_: variable, placeholder, `$1`/`%1%` (the syntax is `{{N}}`); "merge field"

**Async Node**:
A node whose downstream exec pins do **not** fire during the synchronous trigger→…→node sweep,
but later, from an external callback. The Webhook is the first: its firing `run` starts the
POST and returns, and `On Success` / `On Failure` fire when the HTTP completion callback
arrives. Legal because the engine's `ctx` closure stays valid after `run` returns and the
client is single-threaded, so a deferred `ctx:Fire` simply propagates downstream at callback
time. See [ADR-0006](docs/adr/0006-async-continuation-node.md).
_Avoid_: deferred node, callback node, promise; conflating with a Pure Node (that is about
*pull* timing, not *push* timing)

## Testing node types

Node behavior (a node type's `run`) is verified against a **real** `LibNodeGraph` Graph —
`AddNode`, set Controls, drive with `Graph:FireInput(id, execPin)` / `Graph:Fire(id)`, assert
on the observable effect — **never** a hand-built `ctx` table, which is blind to divergence
from the real engine's run context. See `tests/test_screen_marker.lua` /
`tests/test_infobox_node.lua`, and [LibNodeGraph's CONTEXT.md](../LibNodeGraph/CONTEXT.md#the-runctx-contract-and-how-its-enforced)
for the full rationale and the two other guards (the runtime field guard + LuaLS typing).
