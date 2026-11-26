# Watchdog (UI)

The graph-editor UI for Watchdog: an in-client, Unreal-Blueprints-style visual editor
that renders and manipulates a live `LibNodeGraph` Graph. This context owns only
*presentation and interaction* — the graph model, node types, and execution belong to
[LibNodeGraph](../LibNodeGraph/CONTEXT.md). Watchdog UI never invents graph structure; it
draws what the engine holds and calls back into the engine to mutate it.

The editor is drawn entirely on a single `ui.Canvas` in immediate mode (rebuilt each
`Event.Draw` frame), because Canvas is the only client primitive whose coordinates the
plugin fully controls — a prerequisite for pan and zoom.

How a build is installed is named here too.

## Distribution

**Plugin Hub**:
The in-client installer for Remote plugins.
_Avoid_: mod.io (that is the website and the zip task), plugin browser

**Remote plugin**:
A moderated plugin installed from the Plugin Hub. It lives in the game cache's plugins folder, and another plugin references it by numeric id.
_Avoid_: Hub plugin, mod.io plugin, downloaded plugin

**Local plugin**:
A development plugin loaded from the development plugin path. Another plugin references it by folder name.
_Avoid_: Dev plugin, unpacked plugin, source plugin

**Dependency identifier**:
The name a plugin is declared under in a dependency map — the same string the client reports as that plugin's identifier. The map's value is a Local plugin's folder name or a Remote plugin's numeric id.
_Avoid_: Folder, mod id, plugin name (those can differ from this)

**Settings layer**:
The Plugin Hub manage-tab page for this plugin. Watchdog's page holds the manager key, a lock for the infobox and toasts, a note on what a restricted area changes, and whether the chat and tracking permissions are granted. It holds no per-alert settings. The lock keeps the infobox and toasts from being dragged, and clicks on them reach the game. The player-facing name for the window is manager.
_Avoid_: Options menu, config screen, the Alert Manager

**Content layer**:
The in-game panel for this plugin. The player places it, including beside the inventory, and it stays on screen while playing. Watchdog's panel has a button labeled Toggle that opens and closes the manager. The button stays pressed while the manager is open. Closing it from the title bar or with the manager key releases the button, and opening it with the manager key presses the button. An Object Marker capture tucks the window and leaves the button pressed. Under Toggle, one row holds Reset All Popups and Reset Positions. Reset All Popups clears one-shot notices. Reset Positions puts the infobox and the toasts back where they start, and that place is kept. While the player is Restricted, a line under the buttons reads In Restricted Area, in red, and a description under it says nearby spawns, game messages, and spots you chose will not alert you, while other alerts still work. Otherwise the panel is only the buttons. The panel reads the current answer when it is shown, and then follows Restricted changes.
_Avoid_: Settings layer (the manage-tab page)

**Manager**:
The window the player opens to work with alerts. The settings page calls the key that opens it the manager key. That key and the content-layer Toggle both open it. The key defaults to F8. Clearing it on the settings page leaves that key free, and the Toggle button still opens the manager. While an Object Marker capture is armed, the gesture cancels the capture and leaves the manager where it is.
_Avoid_: shell, Open, launch

## Packs

**Pack**:
A named registration of pack sound effects, pack audio files, and Alert Presets. Another plugin can hold one. Watchdog holds one named Watchdog Starter Pack for the starter Alert Presets.
_Avoid_: Addon, Catalog

**Pack name**:
The name a Pack supplies when it registers. Contributions are shown and addressed under it.
_Avoid_: Manifest name, plugin name

**Registration token**:
The hold Watchdog gives a Pack when that Pack's name enters the registry. The name stays taken while the Pack has that hold. Another plugin does not have it.
_Avoid_: Pack name, author id

**Author id**:
The id a Pack author assigns to one pack sound effect, one pack audio file, or one Alert Preset. It is not the label, and it is not the Preset id.
_Avoid_: Listing id, Clip id

**Pack sound effect**:
A Pack contribution offered on the Sound Effect node. It names a client builtin sound id, and the label is separate from its author id. Choosing one stores the Pack name, that author id, and the builtin sound id on the alert. The Sound Effect node plays that builtin sound id whether or not the Pack is still loaded. A raw builtin sound id typed by hand is not a pack sound effect.
_Avoid_: Listing, builtin sound effect, sound effect (the node), catalog entry

**Pack audio file**:
Audio shipped inside a Pack and offered on the Custom Sound node. The label is separate from its author id, and the alert stores the Pack name and that author id. A new play needs that Pack loaded, and a play already started keeps going after that Pack is no longer loaded.
_Avoid_: Clip, custom audio file, custom sound (the node), resource, filename

**Watchdog audio file**:
Audio shipped inside Watchdog and offered on the Custom Sound node beside pack audio files.
_Avoid_: Pack audio file, custom audio file, resource

**Alert Preset**:
A Preset a Pack contributes, offered beside the Preset library while that Pack is registered. It is not a row in that library. The author assigns an author id for that contribution. That author id is not the Preset id. The player adds a copy, which is then an ordinary Alert, and that copy does not keep the author id. The New alert dialog closes, and the copy is on the alert list. Creating an Alert from that copy shows the same chat-permission dialog as creating one from a Preset. The snapshot is a Preset: name, serialized graph, layout, and Variables.
_Avoid_: Import (that is the paste-an-export dialog); a second template type; a Preset library row

## Language

**Shell**:
The Watchdog window. Its Multiplexer swaps the Manager and the Editor, and only one of those is visible.
_Avoid_: Multiplexer (that names the stack, not the window), hub

**Multiplexer**:
A stack of surfaces in one window. Only the top surface is visible, and the window stays mounted while surfaces are pushed and popped.
_Avoid_: Shell, Dialog, tab bar

**Surface**:
One layer on a Multiplexer. The top surface is the one on screen.
_Avoid_: Page, view, screen, tab

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
**Entry**. The Store writes the scope tree apart from each Alert's graph and Layout
([ADR 0022](docs/adr/0022-alert-graphs-are-their-own-keys.md)). See Bucket.
The `global` Bucket + Entry tree landed in #86; the persisted
`current` pointer is gone — the Editor now constructs unbound and the Manager binds it to an alert
on open (#80/#90), so a reload lands on the Manager. Every Store operation keys on the Entry `id`,
never name. Bucket I/O is key-parametrized: `Store.Load`/`Store.Save` are the `global` shorthands
over `Store.LoadKey(key)` / `Store.SaveTo(key, doc)`, and `Store.PlayerKey` builds a
character Bucket's `player_<tracking id>` key. Display-name keys are not read and are not
migrated. Only `Store.Load` runs the one-shot legacy
migration — a character Bucket has no legacy predecessor.
_(Landed: per-character Buckets (#89), the one-shot legacy `watchdog_graphs` migration
(#87), the read-only Alert Manager render + Editor↔Manager navigation (#90), Manager row
editing ops — create / rename / delete / enable (#91), multi-select / bulk actions (#93),
export/import copy-paste with the 9,999-byte guard (#94), and sibling ↑↓ + Lift buttons.
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
The category-colored band at the top of a Node Body. It shows the node type and the Node name
as `{Type} - {Name}`. Its color is keyed off the Node Type's Category.
_Avoid_: Title bar, caption, banner

**Node name**:
The player-chosen name of one node, separate from the node type's display name. A node has no
name until the player renames it, and the header shows `New {Type}` until then.
_Avoid_: Title (that is the Header text), display name (that is the type), label

**Pin label**:
The text shown for a Pin on a node. When a Pin has none, that text is the Pin's name.
_Avoid_: Pin name (that is the key on the node)

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

**Unavailable**:
A Palette row that is shown and cannot be placed. It is dim, it does not highlight, and the reason is drawn after the name. Drag-to-Create does not list these rows. A gate can put a real node type into this state. While chat permission is off, the Game Message trigger, the Player Chat trigger, and the Game Message action each show "needs chat permission". Shortest Path shows "needs Shortest Path" while that plugin is absent. The type stays registered, so a node already on a graph remains. A fire of the Game Message action or Shortest Path does nothing while its gate is closed. The client delivers ChatMessage only when chat permission is granted, so those two triggers stay quiet until then. When the gate opens, the row can be placed again and the next fire runs. Rows whose API does not exist yet stay Unavailable permanently.
_Avoid_: Disabled, hidden, greyed out

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
A Node that compares two numbers and produces a boolean Result. Its Operation Control
selects equality, inequality, greater than, less than, greater or equal, or less or equal.
Changing the Operation leaves the two input Pins and their Wires in place. An unconnected
input stores a number.
_Avoid_: Separate comparison types. Equals and Not Equals, the hidden types that still load
old graphs comparing other values.

**Math**:
A Node that combines two numbers and produces a number Result. Its Operation Control
selects add, subtract, multiply, divide, modulo, minimum, or maximum. Changing the
Operation leaves the two input Pins and their Wires in place.
_Avoid_: Separate arithmetic types. Abs and Negate are their own nodes.

**Life points**:
The pool combat damage is subtracted from. It is not the Hitpoints skill level.
_Avoid_: Hitpoints, HP, constitution

**Resource**:
The pool Resource Changed is watching. One of life points, prayer points, summoning points, adrenaline, or run energy.
_Avoid_: audio file, pack audio file, the Hitpoints skill, the Prayer skill, the Summoning skill, the run toggle

**Run energy**:
The percentage of the run pool. Resource Changed reads the current value from the player, and the maximum is 100.
_Avoid_: run toggle, weight

**Resource Changed**:
A Trigger that fires when the selected Resource's current value changes. It outputs that current value, the maximum, and the previous current value. Changing the selected Resource leaves those outputs in place.
_Avoid_: Stat Changed. A separate trigger per pool.

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
the single-alert Editor. Window chrome is a PrettyUI window on the Shell, and the Shell's Multiplexer swaps the Manager and the Editor inside it.
Content is a **hybrid**: PrettyUI for scope tabs and form controls, native `ui.Panel` rows for
the tree strip (ADR-0007) — see [`docs/alert-manager-prettyui.md`](docs/alert-manager-prettyui.md).
Not the Editor's Canvas. Row **name** is a labeled PrettyUI SimpleButton; row **actions** and
reorder are PrettyUI SpriteButtons (pencil / export / trash, arrows). Destructive delete goes
through a **Confirm dialog**, not a two-click armed label. This vocabulary was settled across
the Alert Manager wayfinder map (#73); each term points at the ticket that fixed it.

**Alert Manager**:
The single management surface the shell toggle opens (`ui/manager.lua`):
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
pushes, dismiss pops; one visual dim directly under the topmost modal, so dialogs below it
are dimmed and stay mounted but inert. While a dialog is open, Maximize and the resize grip are not brought
forward, so they stay under the dim and do not take clicks. Not dismissed by Esc — the client would also open the pause menu. Distinct
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
A leaf Entry (`kind = "alert"`) bundling one saved graph with its Layout and one `enabled` flag on this Entry. The Runtime fires that flag (#75). Alert Toggle and the Manager enable checkbox set it, and a failed save leaves the new value until the next load reads the Bucket.
_Avoid_: Graph (that is the engine model an Alert wraps), rule, trigger, session enable, Runtime alert

**Alert Toggle**:
An Action whose target is an Alert name. It turns on, turns off, or flips every resident Alert with that name, saves each matched Bucket, and keeps the new flag when a save fails.
_Avoid_: Name toggle; the Manager checkbox, which flips one Entry by id

**Preset**:
A player-saved snapshot of one Alert that can be instantiated into a new Alert. Not an Entry,
and not tied to the Alerts created from it. The New alert dialog closes, and the new Alert is on the alert list. Instantiating one shows the chat-permission dialog
when the snapshot contains a Game Message trigger, a Player Chat trigger, or a Game Message
action and chat permission is not granted. The first sentence says this alert includes a Game
Message or Player Chat node.
_Avoid_: Template (that is a Webhook body), pack, starter, rule, Alert Preset

**Preset id**:
The integer that identifies one Preset in the Preset library. It is kept across rename, the player
does not see it, and a new one is one past the highest Preset id still in the library. Among
Presets that share a name, the lower Preset id was saved earlier.
_Avoid_: Entry id, node id, index, UUID

**Preset library**:
The plugin-wide collection of Presets, shown in case-insensitive natural name order. The player
does not arrange that order. Presets that share a name are listed by Preset id, lower first. A Preset saved on any tab is offered in every Scope, including
while logged out. Not a Scope, and not a Bucket: Scope still only partitions Entries.
The instantiated Alert lands in the active Scope. The preset index is `scope_presets` (version 2: id, name, and variables). Each Preset's graph and Layout are `scope_presets_<id>`. The old `presets` value stays on disk and is not written again. The library is not a field of `global` and not stored under any `player_<tracking id>` key, so saving a Scope or switching character does not rewrite it.
_Avoid_: per-Scope library; Bucket. Starter Alert Presets live on Watchdog's own Pack, not in this library.

**Variable**:
A text, number, or enum Control, or the needle of a Matcher, marked on a Preset so that
instantiating it asks the player for that value and bakes the answer into the new Alert.
_Avoid_: Prompt, placeholder, parameter; Injection Token (that is a fire-time `{{N}}` on a Webhook)

**Group**:
A branch Entry (`kind = "group"`) with a `children` array of Entries (alerts and/or nested groups).
Its `enabled` is an **inheritable master switch**: a disabled Group silences its whole subtree, so
an Alert fires iff its own `enabled` AND every ancestor Group's `enabled` are true — the
**enabled-chain** (#75).
_Avoid_: Folder, category, section; "group" as a verb (that is bulk New-group, #82)

**Bucket**:
The per-Scope `PersistentDB` key holding one Scope's tree. Callers pass `global` or `player_<tracking id>`. The stored tree key is `scope_global` or `scope_player_<tracking id>`, version 3, without graphs. Each Alert's graph and Layout are their own key. Legacy `global` and numeric `player_<digits>` values stay on disk and are not written again. The `global` tree also holds
`infoboxAnchor` (the former `current` pointer is no longer persisted — see Level, #80). Keys carry
**no `watchdog_` prefix** — `PersistentDB` is already plugin-scoped (#81). Scope is not
a per-Entry field: changing an Entry's Scope moves its subtree across keys (#75, #77, #81).
Buckets stored under a display name are not read.
_Avoid_: Store slot, namespace, table; "partition" (that names the concept — see Scope)

**Tracking ID**:
The per-character id from `Player.GetTrackingID`. It is the character Bucket's key, used character for character. Watchdog requires the trackingAccess permission to read it. A rename does not change it. Logged out, or an empty id while in game, means there is no character Bucket.
_Avoid_: Display name, account name, uid (`PlayerEntity.uid` is a different field)

**Scope**:
The partition a Bucket represents: `global`, or a single character keyed on that character's Tracking ID. Not a
field on an Entry — an Entry's Scope is simply which Bucket holds it (#75, #77). The character tab's label is the current display name. A loaded Scope is Resident, and Armed is a separate state of that same Scope.
_Avoid_: Profile, player field, owner, context; Bucket (that is the saved key)

**Active scope**:
The Scope new Entries land in — the Manager's currently-selected tab; `global` when logged out. The
selector offers **`global` + the current character only** (#77, #78).
_Avoid_: Selected scope, focus; "current scope" (that word names the deleted Store pointer)

**Armed** / **Resident**:
Two independent runtime states of a loaded Scope (landed in `runtime.lua`, #89). **Resident** =
loaded in memory. **Armed** = eligible to fire: the global Scope is armed at plugin start and never
disarmed; a character Scope arms on the `GAME` transition when its Tracking ID is unchanged (a
world-hop/reconnect re-arms *in place* — no reload, so `pollEdgeState` and `pollSeedKey` survive and no `Enter` is
replayed), disarms but stays resident on leaving `GAME`, and is discarded and reloaded only when the
Tracking ID changes. Revoking `trackingAccess` discards the character bucket. A rename keeps the same Bucket. Identity has no switch event. A **pending-resolve flag drained on
Logic ticks** covers a plugin reload mid-session and a `trackingAccess` grant (`OptionalPermissionChanged`) while already in game. The Runtime fires from armed Scopes. **Fire predicate: armed Scope AND
enabled-chain true — nothing else** (editor state and the Manager's selected Scope never gate
firing) (#77, #89). Entity Spawn, the Game Message trigger, and the Location trigger also stay silent while the player
is Restricted; that silence is those triggers' own rule, not this predicate.
_Avoid_: Active / loaded (ambiguous between the two states), enabled (that is the per-Entry switch), Bucket (a Bucket is the saved key, and it is not armed)

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
A Dialog wrapper with two recipes: **Import** (paste an export) and **Export** (copy one
out). Envelope is `{ schemaVersion, pluginVersion, entries }`; there is no clipboard API, and
save-to-file is designed but disabled until a filesystem API exists (#79). Export still shows that
dead footer action. Import is **append, never merge-by-name**. The wrapper does not import: it asks
the caller to apply the pasted text. A failed apply leaves Import mounted and stacks a message
Dialog on top (closing the error reveals the paste field intact). A successful apply just dismisses
Import. There is no success notice; the Manager tree is the feedback. When the appended entries
contain a Game Message trigger, a Player Chat trigger, or a Game Message action, and chat permission
is not granted, one modal dialog follows. Its title is Chat permission. The body is three sentences:
This import includes a Game Message or Player Chat node. Only those nodes wait on chat permission.
They do nothing until you grant it, and granting it later is enough. The button reads I understand
and uses the primary style. The title-bar X closes it the same way. The imported entries stay,
including their enabled flags. A node inside a group counts, and a disabled alert counts. Alerts
already in the scope do not. A failed apply does not show this dialog. Creating an Alert from a
Preset, including an Alert Preset from the starter pack, shows this same dialog when that graph
contains one of those nodes and chat permission is not granted. Its first sentence says this alert
includes a Game Message or Player Chat node. The other two sentences, the button, and the title-bar
X are the same. A failed create does not show it, and From scratch does not show it. A move to the
other scope does not show it. It does not show when an alert is enabled, when the editor opens,
when chat permission is revoked later, or when the plugin loads. Esc does nothing, the same as
every other dialog. This dialog is
a permission warning, not a success notice. Every export shape (whole scope,
single row, multi-select) passes a uniform **9,999-byte pre-flight guard** on the paste string.
JSON that fits in 9,999 UTF-8 bytes is the paste. JSON over that cap is deflated and wrapped as a
`WD1` token (unpadded URL-safe base64). The guard measures the token and refuses the entire export,
exporting nothing, if the token is still over 9,999 (the `InputField` hard cap). Import accepts a
`WD1` token or the older raw JSON. Export preflight failure is a message Dialog and never opens Export.
_Avoid_: Transfer; Backup; "sync" (import is append, not sync); clipboard (no API); "serialize"
(engine's word); Export / Import (Import comes first); an Import-success Dialog

## Node domain

**Hold**:
The lifetime in seconds of a non-sticky visual effect before it auto-expires. A sticky effect
ignores Hold and remains until dismissed. Shared pin name and semantics across Toast, Popup
(Popup's Hold is the full-opacity middle of its in/out ramp), Screen Marker, and Object Marker.
Screen Flash has no Hold pin. Its lifetime is Cycles.
_Avoid_: TTL, duration, timeout (as the pin/prose name). Cycles (that is Screen Flash's count)

**Screen Flash** (`action.screen_flash`):
An Action that paints a full-screen color pulse on the overlay. Show starts it. Dismiss ends it immediately. Rise and Fall are the two segment lengths in seconds, default 1 and 1. In Shape and Out Shape shape the alpha inside those segments. Instant rise holds peak for the whole Rise. Instant fall holds clear for the whole Fall. Cycles is how many rise-then-fall pairs play, default 3. Cycles of 0, or a negative count, ends the effect before a draw. Sticky ignores Cycles and repeats until Dismiss. A fraction of a cycle ends partway through the next pair. A saved flash with no Sticky value loads sticky. A new flash is not sticky. The starter pack's Screen Flash matches a new one.
_Avoid_: Hold (seconds on Toast, Popup, and the markers), Dismiss On

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
hover is not covered; Esc or the shell key cancels and brings the window back. The shell is restored on a
successful Select Object. If Watchdog was already hidden by the shell key, it stays hidden.
_Avoid_: toast, notification, armed banner, overlay prompt

**Player Input** (`trigger.player_input`):
A Trigger that pulses when any checked local input happens. It listens the whole time its Alert is armed and enabled, and the pulse does not say which input it was. Mouse move, Keyboard, and Mouse click are bool pins, so each one is a checkbox or a wire. Mouse move is the cursor position changing. Keyboard is a key going down. Mouse click is the minimenu opening, an entry being selected, or the minimenu closing. Each of those events pulses on its own. A new Player Input has all three checks on. The starter pack's Player Input does too. An alert already made from that pack is a saved graph, and its checks migrate with the graph.
_Avoid_: Activity, Player Activity, Dismiss On, Menu opened, Menu closed

**Chat Trigger**:
A Trigger Node that fires on the client's `ChatMessage` event. There are two, split by who
authored the line: the **Game Message** trigger (system/engine/broadcast/examine lines) and
the **Player Chat** trigger (lines a player typed — public, private, friends/clan/group).
Each strips formatting tags from the incoming line before matching, so a Matcher never sees
`<col=…>` markup, and exposes only the Chat Type Groups relevant to it. Player Chat's sender
pin is the simple sender name.
_Avoid_: Chat node, message node, chat listener

**Game Message** (action):
An Action that inserts one chat line only the local client sees. It shares its display name with the Game Message trigger and is told apart by category. While chat permission is off it is Unavailable.
_Avoid_: Send chat, public chat, chatbox broadcast

**Chat Type Group**:
A Watchdog-curated, named grouping of raw engine `ChatType` ids exposed as one choice in a
Chat Trigger's type dropdown (e.g. *Examine* = `OBJ_EXAMINE`/`NPC_EXAMINE`/`LOC_EXAMINE`;
*Private (Received)* = the incoming private + quickchat ids). Deliberately **not** 1:1 with
the client's `ChatType` enum — a simplified, useful vocabulary that hides noise types and
folds quick-chat into its parent channel. A Chat Trigger exposes only its own Groups, and
**Any** means the union of that Trigger's Groups, never the whole enum.
_Avoid_: Chat category, chat kind, chat class; "chat type" (that is the raw engine `ChatType`)

**Owned**:
Whether the local player owns a ground-item stack, as reported on an ObjStack event. An Entity Spawn output. False on NPC and player events.
_Avoid_: Owner (Scope avoids that word), isOwner (that is the event field's name)

**Mine only**:
An Entity Spawn control, default off. When on, ground-stack events the player does not own are dropped. NPC and player events still fire.
_Avoid_: Owned-only filter on NPCs, isOwner control

**Restricted**:
The local player is somewhere RestrictedAreas reports as Restricted. While Restricted, the Entity Spawn trigger, the Game Message trigger, and the Location trigger do not Fire. A Location crossing that happens while Restricted does not emit Enter or Leave on the way out. Player Chat, Inventory, Skill, and Logic still Fire. The Game Message action still inserts a line. Effects already showing keep showing. Those triggers stay placeable. If the player's tile cannot be read, RestrictedAreas reports Restricted.
_Avoid_: lite, restricted mode

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
Compare on Item Count Changed's `count`, `prevCount`, or `delta` (or two Item
Counts), not a pin on this node.
_Avoid_: query node; GetTotal; amount Mode; putting ids on a Control

**Item Count Changed**:
A Pure Node in the inventory Category: previous and current Inventory Snapshots, the same
Matcher and Note Filter as Item Count. Publishes `count`, `prevCount`, and signed `delta`
(current minus previous). Empty needle means the Container's total stack quantity, not a
slot identity swap. Previous count comes from the Trigger's frozen prev Snapshot, not
`ctx.state`. A change, a threshold, or "gained only" is Compare/Branch on those numbers
(`delta ~= 0` is the change).
_Avoid_: Matcher on the Inventory Trigger; amount Mode; an exec in or a `changed` exec out;
remembering last-count in node state; per-slot identity tracking

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
_Avoid_: placeholder, `$1`/`%1%` (the syntax is `{{N}}`); "merge field"; Variable (a Preset's author-time fill-in, not this token)

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
