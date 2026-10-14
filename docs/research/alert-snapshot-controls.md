# Saved Alert contents and Control addressing (wayfinder ticket #130)

## The question

What does a saved Alert already contain, and how is one Control addressed inside it, so a Preset can snapshot that Alert and later overwrite only the Controls marked as Variables?

A Variable is a text, number, or enum Control, or the needle of a Matcher. An Injection Token (`{{N}}` on a Webhook body) is not a Variable. This note does not propose a Preset file format.

## Sources consulted

Primary sources, in the order they own the facts:

1. Watchdog persistence: `src/store.lua`, `src/export.lua`, `main.lua` (`persistNow`, `onCreateAlert`).
2. LibNodeGraph graph model and codec: `D:\dev\rs3\LibNodeGraph\graph.lua`, `serialize.lua`, `registry.lua`, `json.lua`, `main.lua`.
3. Watchdog Control specs and Matcher: `src/ui/controls.lua`, `src/ui/controls/*.lua`, `src/matcher.lua`, node `Register` functions under `src/nodes/`, and `D:\dev\rs3\LibNodeGraphStd\compare.lua` for the `compareOperation` pin.
4. Dialog host: `src/ui/dialog.lua`, `src/ui/confirm.lua`, `src/ui/import_export.lua`, `src/ui/manager.lua`, `src/ui/multiplexer.lua`, `main.lua` (`windowParent`), and PrettyUI `D:\dev\rs3\prettyui\src\window.lua` plus `src/core/content_methods.lua`, `src/text_field.lua`, `src/combo_box.lua`.

`CONTEXT.md` supplied the settled names (Alert, Entry, Scope, Dialog, Matcher, Control). It is not cited as a source of the shapes below.

---

## A saved Alert is one Entry in a Scope bucket

A Scope is not a field on an Entry. It is which `PersistentDB` key holds the tree. `Store.Load` / `Store.Save` are the `global` shorthands. `Store.PlayerKey` builds `player_<tracking id>`. `Store.LoadKey` / `Store.SaveTo` read and write that key as one JSON string (`Store.Encode` uses `LibNodeGraph.Json.Default`). The decoded document is a `Watchdog.Bucket`: `{ version, entries, infoboxAnchor }`. `version` is filled with `DOC_VERSION` (2) when missing. `infoboxAnchor` is bucket-level (`{ x, y }` or nil). It is not part of an Alert.

`Watchdog.Entry` (`src/store.lua`) is one node of that tree:

| Field | Alert (`kind = "alert"`) | Group (`kind = "group"`) |
| --- | --- | --- |
| `id` | integer minted by `Store.MintId` (`max(id)+1` over the tree). Every Store op keys on `id`, never `name`. | same |
| `kind` | `"alert"` | `"group"` |
| `name` | display string. Not unique. | same |
| `enabled` | boolean. `Store.normalizeEnabled` treats nil as true (`enabled ~= false`). | same, and it is the inheritable master switch (`Store.EnabledChain`) |
| `graph` | `LibNodeGraph.Serialize` output (`LibNodeGraph.SerializedGraph`) | absent |
| `layout` | on-disk array of `{ id, x, y }`, sorted by `id` | absent |
| `children` | absent | ordered `Watchdog.Entry[]` |

`Store.NewAlertEntry` builds that alert row from a live graph: it stores `LibNodeGraph.Serialize(graph)` and `layoutToArray(layout)`. `Store.UpdateAlertGraph` rewrites `graph` and `layout` on an existing alert id and leaves `enabled` and `name` alone. `Store.RestoreAll` walks `Store.Leaves` (alert rows only), `LibNodeGraph.Deserialize(..., { onUnknown = "placeholder" })`, and returns `{ id, name, graph, layout, enabled }` with layout turned back into a node-id map. A failed deserialize is skipped and logged.

Layout ids are graph node ids. `layoutFromArray` keys the in-memory map by `e.id`. That round-trip is valid because deserialize preserves node ids (next section).

The live editor does not persist a Control by itself. `Editor:setControl` calls `Graph:SetControl` and `runtime:PreloadNode`. `main.lua` `persistNow` later calls `Store.UpdateAlertGraph(boundScope.doc, editor.boundId, editor.graph, editor:GetLayout())` and, when the encoded bucket text changed, `Store.SaveTo`. The bound entry id is transient (`Editor:BindEntry`); it is not a field inside the saved graph.

Export is a different envelope, not the saved Alert. `Export.StripIds` drops the Entry `id` and keeps `kind`, `name`, `enabled`, `graph`, and `layout`. The comment on `Export.StripIds` states that graph and layout node ids are left untouched. `Export.Import` mints new Entry ids (`materializeEntry` / `Store.MintId`). A graph-local node id survives that remint. An Entry id does not.

---

## The serialized graph, and how one Control is addressed

`LibNodeGraph.Serialize` (`serialize.lua` `Serialize.Serialize`, published as `LibNodeGraph.Serialize` from `main.lua`) emits:

```text
{ version = 1,
  nodes = { { id, type, controls, mode? }, ... },  -- sorted by id
  connections = { { fromNode, fromPin, toNode, toPin }, ... } }
```

`controls` is a map keyed by pin name. Values are run through `Registry:GetDataType(pin.dataType).encode` when that function exists; otherwise the Lua value is copied. The only Watchdog registration of that hook is `InventoryTrigger.Register` calling `registry:RegisterDataType("invContainer", { encode = encodeInvContainer, decode = decodeInvContainer })`. Every other tag, including `matcher`, `string`, `number`, and the enum tags, is stored as the live Lua value.

`mode` on a serialized node is the node-instance mode key (`Graph:SetMode` / `Graph:GetMode`). It is omitted when the node type has no `modes`. It is not a Control. `Graph:SetMode` keeps the same node id, drops controls whose pin names vanished, and seeds missing data inputs from the new mode's defaults.

`Serialize.Deserialize` restores each node by setting `graph.nextNodeId = nodeData.id` and then `Graph:AddNode`, and asserts the new id equals the stored id. `graph.nextNodeId` is then `maxId + 1`. Runtime `values` and `state` are not in the serialized graph (`graph.lua` node comment: `values` and `state` are runtime-only).

A Control exists only for a data input pin. `Graph:AddNode` fills `node.controls[pinName]` from the passed table or from `copyDefault(pin.default)`. Exec pins and data outputs are not keys in `controls`.

Address of one Control inside a saved Alert:

1. Scope key (`"global"` or `Store.PlayerKey`).
2. Entry `id` (`Store.FindById`).
3. Node `id` (`graph.nodes` / `SerializedNode.id`).
4. Pin name (key of `node.controls` / `SerializedNode.controls`).

Read and write on a live graph:

- `Graph:GetControl(nodeId, pinName)` returns `node.controls[pinName]`, or nil if the node is missing. It does not check the pin.
- `Graph:SetControl(nodeId, pinName, value)` asserts the node exists and the pin is a data input, then assigns `node.controls[pinName] = value`. The assignment replaces the whole value. There is no per-field setter.

`Graph:_pull` uses a Control only when the pin has no incoming connection. If `_findSourceConnection` finds a wire, the pulled value is the source output, and the stored control is ignored for that fire. The control is still serialized.

Placeholder nodes (`Registry.UNKNOWN_TYPE` = `"__unknown__"`) have no pins. Deserialize stashes the original type, raw `controls`, and `mode` on `node.unknown` and leaves live `controls` empty. `Serialize.Serialize` re-emits `node.unknown.controls` verbatim. `Graph:SetControl` cannot target those pins: the placeholder type has no data inputs, so the assert fails. A later overwrite of a still-unknown node has to edit `node.unknown.controls`, which is the table Serialize writes back.

After `SetControl`, the saved Entry changes only when something calls `Store.UpdateAlertGraph` (or builds a new entry with `Store.NewAlertEntry`) and `Store.SaveTo`. Both rewrite the whole serialized graph, not one key.

---

## Matcher: needle and mode are one Control

The Type Tag is `matcher`. `src/matcher.lua` `Matcher.Test` defines the value:

- `needle` string. Nil or `""` matches every haystack.
- `mode` `"pattern"` uses `string.find(haystack, needle)` (case-sensitive, Lua pattern magic). Any other mode, including missing, uses `string.find(haystack:lower(), needle:lower(), 1, true)` (case-insensitive literal).

Pins that carry this tag declare a default of `{ needle = "", mode = "substring" }` (game message `contains`, player chat `contains` and `senderContains`, entity spawn `nameMatch`, inventory `nameMatch`). There is no `RegisterDataType("matcher")`, so that table is what Serialize writes.

The pin control (`src/ui/controls/matcher.lua`) splits the same table for editing and writes it back whole:

- `needleOf` reads `value.needle` only when `value` is a table and `needle` is a string.
- `modeOf` returns `value.mode` when it is `"pattern"` or `"substring"`, otherwise `"substring"`.
- `rmw` copies both keys into a fresh `{ needle = "", mode = "substring" }`, then the caller changes one field.
- `Matcher.ToggleMode` flips `mode` via the toggle (`"substring"` / `"pattern"`) and `host:Commit`s the whole table.
- `Matcher.EditNeedle` re-reads `host:GetControl()`, sets `needle` from the field (a non-string becomes `""`), and commits the whole table. Empty needle is kept.

`Editor:controlHost` `Commit` calls `Editor:setControl`, which calls `Graph:SetControl(nodeId, pinName, value)`. Overwriting only the needle means read the current table, replace `needle`, and `SetControl` the table. Replacing the pin with a bare string drops `mode`; the next `rmw` or `Matcher.Test` then treats mode as substring.

This `mode` field is not `Graph:SetMode` and not the `object_marker.mode` Control (a `{ tile = true }` table edited by the mode-widget pin control).

---

## Which Type Tags are text, number, enum, or matcher

`Controls.Register` (`src/ui/controls.lua`) maps a Type Tag to a widget, then installs a pin control. `Controls.PinControlFor` returns nil for a tag that was never registered. Widget `"text"` uses `TextField` (`filter = "NONE"`). Widget `"number"` uses `NumberField` (`filter = "NUMERIC"`). Widget `"enum"` uses `Enum.new(choices)`. `TextField.Parse` returns a string (non-string raw becomes `""`). `NumberField.Parse` returns a number, or nil for empty or unparsable input, and `Scalar.Press` does not commit nil.

Tags in the four Variable classes:

**Text** (widget `"text"`, stored Lua string):

- `string` - registered in `Controls.Register` at the bottom of `src/ui/controls.lua`.

**Number** (widget `"number"`, stored Lua number):

- `number` - same file.

**Enum** (choices `{ value, label }`; `Enum.Press` commits the choice `value`, which may be a boolean, number, string, or nil):

| Tag | Registered in | Stored `value` shape |
| --- | --- | --- |
| `bool` | `src/ui/controls.lua` | `true` / `false` |
| `toastIcon` | `src/ui/controls.lua` | `nil` or an integer sprite id |
| `compareOperation` | `Controls.RegisterPinControl` in `src/ui/controls.lua`, module `src/ui/controls/compare_operation.lua` (`Enum.new`) | operator string `"=="`, `"!="`, `">"`, `"<"`, `">="`, `"<="`. Pin is `std.compare` `operation`, default `"=="` (`LibNodeGraphStd/compare.lua` `M.Register`) |
| `skill` | `src/nodes/triggers/skill.lua` | `"any"` or integer skill id `0..28` |
| `gameMessageType` | `src/nodes/triggers/game_message.lua` | chat-type choice from `ChatTypes.Choices` |
| `playerChatType` | `src/nodes/triggers/player_chat.lua` | chat-type choice from `ChatTypes.Choices` |
| `entity_spawn.kind` | `src/nodes/triggers/entity_spawn.lua` | `EntitySpawn.KindChoices()` values |
| `invContainer` | `src/nodes/triggers/inventory.lua` | live value is an `InvType` (`config.Inv.INV` / `BANK`). `encodeInvContainer` writes a numeric id. `decodeInvContainer` maps that id (or the userdata) back to `BANK` or `INV` |
| `invNoteFilter` | `src/nodes/triggers/inventory.lua` | `"both"` / `"noted"` / `"unnoted"` |
| `popup.theme` | `src/nodes/actions/popup.lua` | `Popup.ThemeChoices()` values |
| `popup.icon` | `src/nodes/actions/popup.lua` | `Popup.IconChoices()` values |
| `infobox.icon` | `src/nodes/actions/infobox.lua` | `Node.IconChoices()` values |
| `customSoundResource` | `src/nodes/actions/custom_sound.lua` | resource name strings from `CustomSound.ResourceChoices()` |
| `customSoundBus` | `src/nodes/actions/custom_sound.lua` | bus name strings from `CustomSound.BusChoices()` |
| `shape` | `src/nodes/actions/screen_flash.lua` | `"instant"` / `"fade"` |
| `dismissOn` | `src/nodes/actions/screen_flash.lua` | `"none"` / `"mouse"` / `"keyboard"` / `"both"` |

`compareOperation` is an enum pin control but it does not go through `Controls.Register`'s `widget = "enum"` branch. It is still the `Enum` module: `Press` mounts a dropdown and commits the operator string.

**Matcher** (one tag):

- `matcher` - `Controls.RegisterPinControl("matcher", ...)` in `src/ui/controls.lua`. Stored value is `{ needle, mode }` as above. The Variable is the needle, not the mode field and not a second pin.

Registered tags that are not text, number, enum, or matcher (not Variables under the settled definition):

| Tag | Widget | Stored value |
| --- | --- | --- |
| `color` | `swatch` | `{ r, g, b, a }` table. Hex is only the popup display codec (`Swatch.Format` / `Swatch.Parse`). No data-type `encode`. |
| `coordgrid` | coordgrid pin control | table with `x`, `z`, `level`. `CoordGrid.CommitAxis` copies the table and sets one axis. |
| `screen_marker.rect` | `capture` | rect table or nil |
| `object_marker.object` | `capture` | captured object table or nil |
| `object_marker.mode` | `mode` | table of booleans keyed by mode key, default `{ tile = true }` |

Data-input tags with no pin control (`Controls.PinControlFor` is nil; the value is still a `node.controls` entry when the pin exists): `any` (InfoBox `value`, compare inputs `a` / `b`, inventory viewer `snapshot` is `invSnapshot`), and `invSnapshot` on the item-count nodes. Those pins are not text, number, enum, or matcher.

`src/ui/controls.lua` notes that the client `ComboField` ranks `Add()` entries alphabetically, so the canvas enum editor matches a choice by label text, not by combo id. The committed Control is still the choice `value`.

---

## How the Manager mounts a Dialog

Dialogs are not children of the Manager tree. `main.lua` passes `windowParent` that returns `mux.rootLayer`. `Multiplexer:Mount` creates that layer (or reuses the parent when `useParentAsRoot` is set) and builds the shell `prettyui.Window` on it. `Manager:_dialogParent` calls `windowParent`. `Manager:SetVisible(false)` and `Manager:Unmount` call `Manager:DismissDialogs`, which is `Dialog.dismissAll` on that parent.

`Dialog.mount(parent, opts)` (`src/ui/dialog.lua`):

- Returns nil if `parent` is nil or `prettyui.Window` is missing.
- Resolves `title`, `width` (default 328), `height` (default 150), `modal` (default true), `content`, `actions`, `onDismiss`.
- Creates a centered `prettyui.Window` on `parent` with min and max size locked to that width and height, `destroyOnClose = true`.
- Pushes a frame on a per-parent stack. One dim layer (`alpha` 0.4) and one click blocker sit under the top window. Buried dialogs stay mounted and do not take clicks.
- Calls `opts.content(win)` so the caller fills the body.
- Footer buttons are `win:AddFancyButton`, right-aligned, last action rightmost. A missing `onClick` dismisses. `onClick` returning true dismisses; false or nil leaves the dialog up. Titlebar close runs `onDismiss` (no args, cannot veto) and pops. Esc is not bound.

Call sites on the Manager parent today:

- `Confirm.mount` - `content` is `win:AddText(body)`; actions are Cancel and confirm.
- `ImportExport.mountImport` / `mountExport` - `win:AddText` plus `win:AddTextField` (`maxLength` from `Export.MAX_BYTES`, 9999). A failed import stacks another `Dialog.mount` whose content is `win:AddText`.
- `Manager:_runExport` failure - `Dialog.mount` with `win:AddText`.

`prettyui.Window` is a single-surface content host (`ContentMethods.installSingle(Window)` in `prettyui/src/window.lua`). The body callback can call every method in `content_methods.lua` `COMPONENTS`, including the ones a Variable row needs:

- Text: `win:AddTextField`. `TextField.new` forwards `filter` or `filterMode` and `maxLength` to `ui.InputField:Setup`. `GetText` / `SetText` are strings (`root.content`).
- Number: the same `AddTextField` with a numeric filter. The editor's number control uses `ui.InputFieldFilterMode` via `filter = "NUMERIC"` and commits `NumberField.Parse` (a Lua number). `AddSlider` also exists on the window; the stored number Control is not a slider value.
- Enum: `win:AddComboBox`. `ComboBox.new` uses `options.entries` or `options.choices`. Entries that carry an integer `order` go to `OrderedComboBox`. Without `order`, it builds a native `ui.ComboField`. `onChange` receives the entry id and `GetSelectedLabel()`. The canvas editor's label-matching note (above) is about that native combo ranking.
- Bool Variables are the `bool` enum (`true` / `false` labels), not a checkbox. `AddCheckboxButton` exists on the window; nothing in the Control registry stores a bool through it.
- Matcher needle: a string, so `AddTextField` can hold it. Matcher mode is the other field of the same table (`"substring"` / `"pattern"`), which a combo or radio can represent. The Dialog API has no Matcher widget. Committing still means `Graph:SetControl` of the whole `{ needle, mode }` table.

`AddText` is a label, not an editable Control. Footer `AddFancyButton`s are the dismiss/apply actions, separate from the body.
