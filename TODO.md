- [x] Split scope storage so each alert graph is its own PersistentDB key. Accepted in [ADR 0022](docs/adr/0022-alert-graphs-are-their-own-keys.md). Spec: [#182](https://github.com/GrynjolfLabs/rs3-Watchdog/issues/182). Tickets: [#183](https://github.com/GrynjolfLabs/rs3-Watchdog/issues/183) failed saves stay failed, then [#184](https://github.com/GrynjolfLabs/rs3-Watchdog/issues/184) scope round-trip, then [#185](https://github.com/GrynjolfLabs/rs3-Watchdog/issues/185) migration and presets, then [#186](https://github.com/GrynjolfLabs/rs3-Watchdog/issues/186) edits write only the changed key.

> **Node architecture is being charted as a wayfinder map:**
> [Wayfinder: Watchdog trigger/action node architecture](https://github.com/adamk33n3r/rs3-Watchdog/issues/1)
> (GitHub issue #1). The per-node feasibility notes below are the source of truth that map's
> tickets design against.

- [x] 1. consolidate the comparison nodes into one with a dropdown selector for the operation. it's clutter to have 6 different nodes to just change the operation between two numbers. ([#64](https://github.com/adamk33n3r/rs3-Watchdog/issues/64)) _(Palette node is `std.compare` with an operation dropdown. The six old types stay registered and hidden so saved graphs still load.)_
- [ ] 2. By default, exec IN pins allow more than one connection but can be configured to only allow a single connection ([#65](https://github.com/adamk33n3r/rs3-Watchdog/issues/65))
- [x] 3. Right now you can create multiple duplicate connections. If you try to create a connection that already exists, treat that as the user wanting to remove that existing connection. _(Engine: `Connect` now returns `id` or `nil, reason` — uniform result contract, no asserts — and rejects exact-duplicate edges (`"duplicate"`, checked before `"data_input_occupied"`); new `Graph:FindConnection`. Editor `linkPins`: identical wire → toggle off (uniform exec+data); different-source data occupant → replace.)_
- [x] 4. checkbox control for booleans ([#112](https://github.com/adamk33n3r/rs3-Watchdog/issues/112)) _(A bool pin is a checkbox, and so is that pin in the Preset variable dialog. A click stores the flipped boolean.)_
- [ ] 5. add prefix config to Log ([#67](https://github.com/adamk33n3r/rs3-Watchdog/issues/67))
- [ ] 6. when drag-and-dropping a connection line and it opens the palette, can we keep rendering the connection line until the palette is closed either by dismissing or selecting a node? ([#68](https://github.com/adamk33n3r/rs3-Watchdog/issues/68))
- [ ] 7. stateful nodes should display what state they are in. counter should display the current number, flipflop should display what side it will fire next, doonce and gate should display if it is open or closed ([#69](https://github.com/adamk33n3r/rs3-Watchdog/issues/69))
- [ ] 8. ToString supporting enums somehow. Strength is just the number 2 so piping it to ToString just turns it into `"2"`. It can't know it is a skill. Could add a dropdown to ToString to select an enum to transform. Or maybe a new node. ([#22](https://github.com/adamk33n3r/rs3-Watchdog/issues/22))
- [x] 9. Dragging text to the right side of the editor window causes it to wrap.
- [ ] 10. Concat node to combine strings ([#70](https://github.com/adamk33n3r/rs3-Watchdog/issues/70))
- [ ] 11. Make any dropdowns that have "Any" put "Any" at the top. ([#66](https://github.com/adamk33n3r/rs3-Watchdog/issues/66) — combined with #4)
- [x] 12. Screen Marker and Object Marker need a "hold" control like Toast. They also need their "armed modes" to be more noticable with instructions. Screen marker should have a "dimming overlay" and when you drag a box, it's not dim inside. like how windows snipping tool works. And object marker needs to have some sort of indicator that it's enabled and that you need to examine an object. maybe just a big text notification type thing in the top of the screen. ([#71](https://github.com/adamk33n3r/rs3-Watchdog/issues/71))
- [x] 13. Location trigger node needs to not fire upon 1. load and 2. setting position ([#72](https://github.com/adamk33n3r/rs3-Watchdog/issues/72))
- [x] 14. Hide watchdog window during object select _(Mux `HideForCapture` while `objectMarkerCapture` is armed; restore on commit/Esc/F8. No-op if the shell was already down.)_
- [ ] 15. Area select + copy/paste in editor view
- [x] 16. Disabling an alert that has an infobox in it should clear that infobox (and probably any other visuals spawned by that alert) _(Disable, name toggle, group disable, and delete release that alert's InfoBox, toasts, marker/flash handles, and popups stamped with the node's state. Re-enable does not restore them. RemoveAlert alone keeps visuals so a bucket move does not blank an enabled alert.)_
- [x] 17. Add scrolling to main manager view and also preset modal
- [x] 18. Look into rounding the node layout positions to whole numbers so that the json is smaller ([#154](https://github.com/adamk33n3r/rs3-Watchdog/issues/154)) _(Place and drag release store an integer. A save writes that integer. A mid-drag save does not snap the node under the cursor. Load leaves an old fraction alone.)_
- [x] 19. consolidate the math nodes like we did for the compare node ([#154](https://github.com/adamk33n3r/rs3-Watchdog/issues/154)) _(Palette node is `std.math`. The seven old arithmetic types stay registered and hidden.)_
- [x] 20. the new compare node should only accept numbers and also should have a number field when the pin is not connected just like the old ones ([#154](https://github.com/adamk33n3r/rs3-Watchdog/issues/154)) _(`std.compare` inputs are numbers defaulting to 0. A new string, bool, or any wire is refused. A wire already saved still loads.)_
- [x] 21. bundle some good example presets and alerts ([#154](https://github.com/adamk33n3r/rs3-Watchdog/issues/154)) _(Watchdog Starter Pack: Friend login, Idle XP, Tick Counter, Low life points, Low prayer. Copies are ordinary Alerts. A missing global Bucket stays empty.)_
- [x] 22. close palette when opening dialog _(A toolbar button press closes the Palette before that button runs.)_
- [ ] 23. add chat picker
- [ ] 24. look into other inventories (like wood/ore box)

## Node port backlog (mirroring runelite-watchdog)

Target: mirror the trigger/notification list from https://github.com/adamk33n3r/runelite-watchdog
(`TriggerType.java` / `NotificationType.java`). Their "notifications" = our "actions".

### Triggers

- [x] Game Message — `trigger.game_message`
  - `Event.ChatMessage` → payload `chatMessage` (String), `chatType` (ChatType), `timestamp`. Filter `chatType` to the game/engine types (GENERAL=0, ENGINE=4, SPAM=109, broadcasts, etc.). Palette Unavailable with "needs chat permission" until `chatAccess` is granted, same gate as the Game Message action. The type stays registered.
- [x] Player Chat Message — `trigger.player_chat`
  - `Event.ChatMessage` (same event) → filter `chatType` to player-typed lines: PUBLIC=2, FRIEND_CHAT=9, CLANCHANNEL\_\*, GROUP\_\*, PRIVATE_INCOMING/OUTGOING, and their QUICKCHAT variants. Same Palette gate and reason as Game Message.
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
- [x] Inventory — occupancy + snapshots (`trigger.inventory`, #98), Item Count (`inventory.item_count`, #99), Item Count Changed (`inventory.item_count_changed`, #100)
  - `Event.InventoryUpdated` for Container Inventory (`Inv.INV`) or Bank (`Inv.BANK`). Occupancy outs (prev/current used slots, isFull, isEmpty) and frozen `invSnapshot` pins. Item matching is Item Count. Item Count Changed is a Pure Node publishing `count`, `prevCount`, and `delta`. Edges are Compare/Branch on those numbers, not Modes on this Trigger.
- [x] Location — near a set location
  - NO EVENT, but POLLABLE. No position-change event; poll `Player.GetEntity().coordGrid` (CoordGrid) or `.position` (Vector3) on `Event.Logic` (~50/s) and test distance against the target coord. `Player.IsAvailable()` guards logged-out state.

### Actions

- [x] Sound Effect — `action.sound`
  - `audio.Play(builtinResourceID, params?)` with a builtin sound id. `bus` is the shared `audioBus` dropdown (Master, SFX, Music, Ambient, Voiceover; default SFX), same list as Custom Sound. `volume` (0-100, default 100) and `loops` (default 0) match Custom Sound and scale the same way at play time. Done.
- [x] Custom Sound — `action.custom_sound` (#33)
  - `audio.Play(resource, params?)` where `resource` = `Plugin.resources[name]`, picked via an interim dropdown Control (enumerated from `Plugin.resources` at Register time — a disk file-picker is API-blocked/out of scope). `volume` (1.0)/`loops` (0) pins. `bus` is the shared `audioBus` dropdown (Master, SFX, Music, Ambient, Voiceover; default SFX), resolved to `audio.AudioBus` at play time. Resources are never Unloaded, preload-on-reference via a new generalized `preload(node)` node-type hook (`runtime.lua`'s `PreloadNode`/`PreloadGraph`), called on graph-restore (`Runtime:AddAlert`) and control-commit (`ui/graph.lua`'s new `Editor:setControl`, the one path every Control edit now commits through) — plus an on-demand backstop in `run` itself. BUILD-VERIFY: `Plugin.resources` enumerable via `pairs`, `PluginResource:Load()`, `audio.SoundPlaybackParams` fields.
- [ ] Text to Speech
  - VIA ELEVENLABS HTTP + BLOCKED ON FILE WRITE (as in the RuneLite version). No built-in synthesis; instead POST the text to the ElevenLabs API: `HTTPRequest.new(Plugin.urls[...], path)` → `:AddHeader("xi-api-key", ...)` / content-type → `:Post(body, onDone)`, needs the `httpAccess` permission + a manifest base URL. The returned MP3 arrives in `request.data`. Playback is the blocker: `audio.Play` only accepts a builtin id or a disk-backed `PluginAudioResource` (`Plugin.resources[file]`) — there's no in-memory bytes→audio path — so the response must be written to disk (also how the RuneLite version caches it) before it can be played. That needs file-write permission, which isn't available yet (reportedly being worked on). Unblocks once file write lands.
- [x] Game Message — `action.game_message` (#116)
  - One client-side line via `Chat.AddMessage`. Exec-in plus a message string, no exec-out, same shape as Log. Unavailable with "needs chat permission" until `chatAccess` is granted (`OptionalPermissionChanged`); a fire while the gate is closed logs that reason and inserts nothing. Removed from the permanent Unavailable list so it is not also the old "no chat-injection API" row.
- [ ] Overhead — display overhead text
  - NO API. No overhead-text field/method on `PlayerEntity`/`NPCEntity` and no set-overhead call (same gap as the Overhead Text trigger). Not achievable.
- [x] Screen Flash — `action.screen_flash`
  - SELF-DRAWN dismiss-only EffectRegistry effect (#29 overlay Canvas): two hardcoded 25-tick rise/fall segments, each shaped `instant`/`fade` by its own dropdown, repeating until dismissed. Full RGBA `color` (alpha = peak alpha). `Dismiss` exec pin + `dismissOn` dropdown (none/mouse/keyboard/both) driven by `runtime.keyboardActivityTick`/`mouseActivityTick`. Concurrency Replace (re-Show restarts). Done (#37).
- [x] Toast — toast notification — `action.toast` (#36) _(was "Overlay" — legacy RuneLite name, renamed)_
  - SELF-DRAWN via Canvas on the #29 effect overlay (not `ui.GroupBox`). `toast.lua`'s ToastStack owns one shared, cap-10-evict-oldest toast stack across every Toast node, 5s default TTL (now overridable per-node via the `hold` config pin, mirroring Popup) / sticky-until-dismissed, same-node re-fire stacks, dismiss clears one node's toasts. Anchor drag/persistence math is unit-tested (`tests/test_toast.lua`); the drag capture mount and `ctx.pin`/`ctx.nodeId` field names are BUILD-VERIFY against the real engine (absent from the sandbox this was built in).
- [x] Popup — like collection log / league task popup — `action.popup`
  - SELF-DRAWN. No native popup API (confirmed vs docs); emulated on the always-on overlay (#29), animated in->hold->out over Logic ticks and auto-expiring (only HOLD is configurable, ~4s default). Queue-only. Single `body` data pin; `title`/`icon`/`theme`/`hold` are node-config (Control-only pins). Themes: Parchment (canvas primitive, default), Leagues Gold / Red / Red-Gold, and Leagues 2 Gold / Green / Green-Gold. The cache ribbon sprites are gone, so the image themes assemble `resources/images` (Leagues 1: tiled background, header/footer/side trim, 3-part ribbon; Leagues 2: header panel, footer gem, 3-part ribbon) as `ui.Sprite`s. Curated icon dropdown reuses the enum Control. See `nodes/actions/popup.lua`.
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
- [x] Shortest Path (action) — `action.shortest_path`, gated on the optional plugin (#116). Unavailable with "needs Shortest Path" while that plugin is absent; `OptionalDependencyChanged` flips the gate without reloading Watchdog.
- [ ] Plugin Message (action) — inter-plugin messaging; RS3 deps are declared/hard-only, no arbitrary message bus
- [ ] Plugin Toggle (action) — no RS3 API to toggle another plugin
- [ ] Notification Event (action) — same cross-plugin event problem as Notification Fired
