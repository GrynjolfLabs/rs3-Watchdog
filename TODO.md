> **Node architecture is being charted as a wayfinder map:**
> [Wayfinder: Watchdog trigger/action node architecture](https://github.com/adamk33n3r/rs3-Watchdog/issues/1)
> (GitHub issue #1). The per-node feasibility notes below are the source of truth that map's
> tickets design against.

- [ ] **Deferred — Alert Manager row drag polish (#92):** native `dragConfig` is horizontal-only; hybrid on `wip/drag-rows` is finicky (gesture start, ghost Y offset, drops). Full notes + recommended next pass: [`docs/deferred/alert-manager-row-drag.md`](docs/deferred/alert-manager-row-drag.md).
- [ ] 1. consolidate the comparison nodes into one with a dropdown selector for the operation. it's clutter to have 6 different nodes to just change the operation between two numbers. ([#64](https://github.com/adamk33n3r/rs3-Watchdog/issues/64))
- [ ] 2. By default, exec IN pins allow more than one connection but can be configured to only allow a single connection ([#65](https://github.com/adamk33n3r/rs3-Watchdog/issues/65))
- [x] 3. Right now you can create multiple duplicate connections. If you try to create a connection that already exists, treat that as the user wanting to remove that existing connection. _(Engine: `Connect` now returns `id` or `nil, reason` — uniform result contract, no asserts — and rejects exact-duplicate edges (`"duplicate"`, checked before `"data_input_occupied"`); new `Graph:FindConnection`. Editor `linkPins`: identical wire → toggle off (uniform exec+data); different-source data occupant → replace.)_
- [ ] 4. checkbox control for booleans ([#66](https://github.com/adamk33n3r/rs3-Watchdog/issues/66) — combined with #11)
- [ ] 5. add prefix config to Log ([#67](https://github.com/adamk33n3r/rs3-Watchdog/issues/67))
- [ ] 6. when drag-and-dropping a connection line and it opens the palette, can we keep rendering the connection line until the palette is closed either by dismissing or selecting a node? ([#68](https://github.com/adamk33n3r/rs3-Watchdog/issues/68))
- [ ] 7. stateful nodes should display what state they are in. counter should display the current number, flipflop should display what side it will fire next, doonce and gate should display if it is open or closed ([#69](https://github.com/adamk33n3r/rs3-Watchdog/issues/69))
- [ ] 8. ToString supporting enums somehow. Strength is just the number 2 so piping it to ToString just turns it into `"2"`. It can't know it is a skill. Could add a dropdown to ToString to select an enum to transform. Or maybe a new node. ([#22](https://github.com/adamk33n3r/rs3-Watchdog/issues/22))
- [x] 9. Dragging text to the right side of the editor window causes it to wrap.
- [ ] 10. Concat node to combine strings ([#70](https://github.com/adamk33n3r/rs3-Watchdog/issues/70))
- [ ] 11. Make any dropdowns that have "Any" put "Any" at the top. ([#66](https://github.com/adamk33n3r/rs3-Watchdog/issues/66) — combined with #4)
- [ ] 12. Screen Marker and Object Marker need a "hold" control like Toast. They also need their "armed modes" to be more noticable with instructions. Screen marker should have a "dimming overlay" and when you drag a box, it's not dim inside. like how windows snipping tool works. And object marker needs to have some sort of indicator that it's enabled and that you need to examine an object. maybe just a big text notification type thing in the top of the screen. ([#71](https://github.com/adamk33n3r/rs3-Watchdog/issues/71))
- [ ] 13. Location trigger node needs to not fire upon 1. load and 2. setting position ([#72](https://github.com/adamk33n3r/rs3-Watchdog/issues/72))

## Node port backlog (mirroring runelite-watchdog)

Target: mirror the trigger/notification list from https://github.com/adamk33n3r/runelite-watchdog
(`TriggerType.java` / `NotificationType.java`). Their "notifications" = our "actions".

### Triggers

- [x] Game Message — `trigger.chat`
  - `Event.ChatMessage` → payload `chatMessage` (String), `chatType` (ChatType), `timestamp`. Filter `chatType` to the game/engine types (GENERAL=0, ENGINE=4, SPAM=109, broadcasts, etc.).
- [x] Player Chat Message — `trigger.chat` (same node, chat-type-aware)
  - `Event.ChatMessage` (same event) → filter `chatType` to player-typed lines: PUBLIC=2, FRIEND_CHAT=9, CLANCHANNEL\_\*, GROUP\_\*, PRIVATE_INCOMING/OUTGOING, and their QUICKCHAT variants.
- [ ] Overhead Text
  - NO EVENT. The API has no overhead-text event and `PlayerEntity`/`NPCEntity` expose no overhead/chat-text field (only uid, displayName, position, coordGrid, facing). Not achievable with the current API — needs a Jagex-side event.
- [x] Stat Changed — boosts/drains
  - `Event.SkillTransmit` → `skill` (SkillType), `oldXP`, `newXP`, `oldGameplayLevel`, `newGameplayLevel`. Boost/drain = `newGameplayLevel != oldGameplayLevel` (temporary level move). Also `Event.RunEnergyTransmit` (`old/newRunEnergy`) and `Event.RunWeightTransmit` (`old/newRunWeight`) if we expand beyond skills.
- [x] XP Drop
  - `Event.SkillTransmit` (same event) → an XP drop is `newXP > oldXP`; delta = `newXP - oldXP`, skill = `skill`. Note: fires per-skill on any XP change.
- [ ] Sound Fired — when a sound effect plays
  - NO EVENT. The `audio` module is output-only (`audio.Play`, `SoundInstance:Start/Stop/...`); there is no hook for game-played sounds. Not achievable with the current API.
- [x] Spawned Object — object/player/npc spawn or despawn
  - `Event.NPCEntityAdded` / `Event.NPCEntityRemoved` (`npcEntity`), `Event.PlayerEntityAdded` / `Event.PlayerEntityRemoved` (`playerEntity`), `Event.ObjStackEntityAdded` / `Event.ObjStackEntityRemoved` / `Event.ObjStackEntityChanged` (`objStackEntity`, `objType`, `count`/`old+newCount`). One node likely fans out over all three entity kinds + add/remove.
- [ ] Inventory — full, empty, or contains certain items
  - NO DIRECT API. No inventory/container-contents read and no inventory-change event exist (`InvType` is config only — id/size/stockCount). Partial signals may be derivable from `Event.VarTransmit` for specific inventory-related varbits (`var`, `oldValue`, `newValue`), but there is no general "what's in my inventory" query. Needs investigation / likely blocked on a Jagex-side container API.
- [x] Location — near a set location
  - NO EVENT, but POLLABLE. No position-change event; poll `Player.GetEntity().coordGrid` (CoordGrid) or `.position` (Vector3) on `Event.Logic` (~50/s) and test distance against the target coord. `Player.IsAvailable()` guards logged-out state.

### Actions

- [x] Sound Effect — `action.sound`
  - `audio.Play(builtinResourceID, params?)` with a builtin sound id, `bus` hardcoded `sfx` (#33 retrofit). Done.
- [x] Custom Sound — `action.custom_sound` (#33)
  - `audio.Play(resource, params?)` where `resource` = `Plugin.resources[name]`, picked via an interim dropdown Control (enumerated from `Plugin.resources` at Register time — a disk file-picker is API-blocked/out of scope). `volume` (1.0)/`loops` (0) pins, `bus` hardcoded `sfx`. Resources are never Unloaded, preload-on-reference via a new generalized `preload(node)` node-type hook (`runtime.lua`'s `PreloadNode`/`PreloadGraph`), called on graph-restore (`Runtime:AddAlert`) and control-commit (`ui/graph.lua`'s new `Editor:setControl`, the one path every Control edit now commits through) — plus an on-demand backstop in `run` itself. BUILD-VERIFY: `Plugin.resources` enumerable via `pairs`, `PluginResource:Load()`, `audio.SoundPlaybackParams` fields.
- [ ] Text to Speech
  - VIA ELEVENLABS HTTP + BLOCKED ON FILE WRITE (as in the RuneLite version). No built-in synthesis; instead POST the text to the ElevenLabs API: `HTTPRequest.new(Plugin.urls[...], path)` → `:AddHeader("xi-api-key", ...)` / content-type → `:Post(body, onDone)`, needs the `httpAccess` permission + a manifest base URL. The returned MP3 arrives in `request.data`. Playback is the blocker: `audio.Play` only accepts a builtin id or a disk-backed `PluginAudioResource` (`Plugin.resources[file]`) — there's no in-memory bytes→audio path — so the response must be written to disk (also how the RuneLite version caches it) before it can be played. That needs file-write permission, which isn't available yet (reportedly being worked on). Unblocks once file write lands.
- [ ] Game Message — chat message out (distinct from `action.log`, which is a debug logger, not a port of this)
  - NO API. There is no way to inject a NEW chat line. `Event.ChatMessage`'s `chatMessage` is writeable but only mutates an INCOMING message; `ExecuteConsoleCommand` runs console commands, not chat (confirmed vs docs). `action.log` (→ Lua console via `log()`) stays our only text-out; a true in-game chatbox message is blocked.
- [ ] Overhead — display overhead text
  - NO API. No overhead-text field/method on `PlayerEntity`/`NPCEntity` and no set-overhead call (same gap as the Overhead Text trigger). Not achievable.
- [x] Screen Flash — `action.screen_flash`
  - SELF-DRAWN dismiss-only EffectRegistry effect (#29 overlay Canvas): two hardcoded 25-tick rise/fall segments, each shaped `instant`/`fade` by its own dropdown, repeating until dismissed. Full RGBA `color` (alpha = peak alpha). `Dismiss` exec pin + `dismissOn` dropdown (none/mouse/keyboard/both) driven by `runtime.keyboardActivityTick`/`mouseActivityTick`. Concurrency Replace (re-Show restarts). Done (#37).
- [x] Toast — toast notification — `action.toast` (#36) _(was "Overlay" — legacy RuneLite name, renamed)_
  - SELF-DRAWN via Canvas on the #29 effect overlay (not `ui.GroupBox`). `toast.lua`'s ToastStack owns one shared, cap-10-evict-oldest toast stack across every Toast node, 5s default TTL (now overridable per-node via the `hold` config pin, mirroring Popup) / sticky-until-dismissed, same-node re-fire stacks, dismiss clears one node's toasts. Anchor drag/persistence math is unit-tested (`tests/test_toast.lua`); the drag capture mount and `ctx.pin`/`ctx.nodeId` field names are BUILD-VERIFY against the real engine (absent from the sandbox this was built in).
- [x] Popup — like collection log / league task popup — `action.popup`
  - SELF-DRAWN. No native popup API (confirmed vs docs); emulated with a Canvas-drawn banner on the always-on overlay Canvas (#29), animated in->hold->out over Logic ticks and auto-expiring (only HOLD is configurable, ~4s default). Queue-only. Single `body` data pin; `title`/`icon`/`theme`/`hold` are node-config (Control-only pins). Two themes behind a dropdown — Parchment (primitive, default) + Leagues (multi-part `RS3_RIBBON_LEAGUES_GOLD_*` sprites) — with a `Popup.RegisterTheme` seam; curated icon dropdown reuses the enum Control. See `nodes/actions/popup.lua`.
- [x] Screen Marker — `action.screen_marker`
  - SELF-DRAWN dismiss-only EffectRegistry effect (#29 overlay Canvas): a persistent border box drawn via Canvas `AddOutline`, `thickness` + `color` data pins. The rect is draw-only — a "Draw on screen" button (`ui/screen_marker_capture.lua`) arms a transient full-screen capture overlay (drag corner→corner writes one `{x,y,w,h}` param, pixels, no clamp; Esc cancels), not a typed field and not #18's composite-control framework. Nil rect never fires; concurrency idempotent/Replace (one marker per node, Stack capped at 1; different nodes stack). Done (#39).
- [x] Object Marker
  - SELF-DRAWN via `ScreenConvert`. Each `Event.Draw`, project a world tile/entity to screen — `entity.position`/`.coordGrid` (from `Player.GetEntity()`, `NPCList`/`ObjStackList`, or a fixed `CoordGrid`) → `ScreenConvert.CoordGridToScreen(coordGrid, heightAboveGround)` (or `Vector3ToScreen`) → draw on Canvas. Exactly the `DevTools/overlay.lua` tile-marker pattern; must re-project every frame since the camera moves.
- [ ] Counter — increment a counter (may just reuse `LibNodeGraphStd`'s `std.counter` instead of a dedicated node)
  - INTERNAL, no API. Value via `LibNodeGraphStd` `std.counter`; optional on-screen display is a self-drawn `ui.Text`.
- [ ] Alert Toggle — toggle an alert's enabled state
  - INTERNAL, no API. Flip a Watchdog alert/graph's `enabled` flag in Watchdog state.
- [ ] Dismiss Toast
  - INTERNAL, no API. Remove a Watchdog-owned Toast (from the action above) by id — pure bookkeeping over our own state, not a game-side registry.
- [x] Dismiss Screen Marker
  - INTERNAL, no API. Folded into `action.screen_marker`'s own `dismiss` exec-in pin (#39's #3 dismiss idiom) rather than a separate node type, same as Screen Flash's Dismiss pin.
- [ ] Dismiss Object Marker
  - INTERNAL, no API. As above, for a Watchdog-owned Object Marker.
- [ ] Request Focus — request focus on the window
  - NO API. No programmatic focus-request method; only the read-only `Event.WindowFocusChanged` (confirmed vs docs). Not achievable.

### Not supported (no RS3 plugin API equivalent currently)

- [ ] Notification Fired (trigger) — cross-plugin notification bus doesn't exist on RS3
- [ ] Tray Notification (action) — no OS tray access
- [ ] Dink (action) — RuneLite-specific 3rd-party webhook plugin integration
- [ ] Shortest Path (action) — RuneLite-specific 3rd-party plugin integration
- [ ] Plugin Message (action) — inter-plugin messaging; RS3 deps are declared/hard-only, no arbitrary message bus
- [ ] Plugin Toggle (action) — no RS3 API to toggle another plugin
- [ ] Notification Event (action) — same cross-plugin event problem as Notification Fired
