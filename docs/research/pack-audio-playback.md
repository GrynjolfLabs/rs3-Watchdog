# Pack audio playback (wayfinder ticket #121)

## The question

A Clip is an audio file that ships inside a Pack plugin, not inside Watchdog. Custom Sound today only plays entries from Watchdog's own `Plugin.resources.audio`, by passing that resource to `audio.Play`.

Can Watchdog play a `PluginAudioResource` owned by another plugin? What can the Pack hand across the plugin boundary: the resource object, a file name, or only a function that plays the sound inside the Pack's own Lua state? What has to be true for that playback to work (`Load`, how long the resource stays valid, which bus)?

Sources consulted:

1. Client API docs, fetched for this note:
   - https://d1s24e1pcksyf8.cloudfront.net/audio/index.html
   - https://d1s24e1pcksyf8.cloudfront.net/core/plugin.html
   - https://d1s24e1pcksyf8.cloudfront.net/structure.html
   - https://d1s24e1pcksyf8.cloudfront.net/tutorial/5database.html (per-plugin database only)
   - The docs search index at https://d1s24e1pcksyf8.cloudfront.net/search.json, used to find those pages. `audio.html` at the site root returns Access Denied; the live page is `audio/index.html`.
2. Local stubs at `D:\dev\rs3\runescape-api-stubs`, as a cross-check. They lag the live pages. Discrepancies are called out below. The stub is not treated as winning where the live page says more.
3. Measured notes on dependency globals: `D:\dev\rs3\docs\agents\plugin-runtime.md` and `D:\dev\rs3\.memory\rs3-plugin-dependency-model.md`, plus the reload note in `D:\dev\rs3\.memory\plugin-reload-wipes-state.md` and `D:\dev\rs3\.memory\api-data-is-userdata.md`.
4. Watchdog's own source, for what this plugin does today. Not as proof of a client capability.

`TODO.md` is not used as evidence. Its Custom Sound line describes `Plugin.resources[name]`, which is neither what `custom_sound.lua` does nor what the live plugin page says.

The docs site was accessible. Every client claim below is tied to a page. Where the pages do not say, this note says they do not say.

---

## Answer

Watchdog cannot play a Clip from a file name. The docs do not show `audio.Play` accepting a `PluginAudioResource` owned by another plugin, and nothing in the measured notes shows that either. The audio value the docs do say can cross plugins is a `SoundInstance`, after some plugin has already called `audio.Play`.

A Pack depends on Watchdog. Watchdog does not receive the Pack as a global. The Pack is the plugin that can see both the ogg and the `Watchdog` table. The playback the docs fully specify is the Pack calling `audio.Play` on an entry from its own `Plugin.resources`, while that Pack stays loaded.

A function the Pack hands to Watchdog, so Watchdog can invoke playback later inside the Pack, is not described. Do not treat it as a client capability. It is the remaining design question, and it needs an in-client probe.

---

## What `audio.Play` accepts

https://d1s24e1pcksyf8.cloudfront.net/audio/index.html#audioplay

```
function audio.Play(resource : PluginAudioResource, params : audio.SoundPlaybackParams?) -> audio.SoundInstance?
function audio.Play(builtinResourceID : Int, params : audio.SoundPlaybackParams?) -> audio.SoundInstance?
```

"Creates an instance for an audio resource that can then be played back." The resource parameter is "The plugin-provided audio resource to create a sound instance for." The other overload is "Numeric ID for the built-in audio resource."

The overview on the same page: "The audio system allows plugins to create sound instances for builtin sound resources or for their custom audio resources, and control their playback."

Both examples on that page pass the caller's own table: `audio.Play(Plugin.resources.click_long)` and `audio.Play(Plugin.resources.click, soundParams)`. There is no example that passes a resource obtained from another plugin.

The return is "The newly created sound instance, or nil if resource loading or we were already at the maximum number of live sound instances." The sentence is incomplete in the docs ("nil if resource loading"), but the two failure cases it names are a load failure and the mixer cap. The same page warns that leaving instances dormant can hit that cap.

The stub at `runescape-api-stubs/generated/audio.lua:56-61` has the same two overloads and the same nil causes. It does not add an owner parameter, and it does not add a bytes overload. There is no third way to play audio on this page.

"Their custom audio resources" is the closest the page comes to ownership. It does not say "only a resource from the plugin that calls `audio.Play`", and the signature does not check an owner. It also does not say a resource owned by plugin A may be passed into plugin B's `audio.Play`. The only documented way to obtain a `PluginAudioResource` is the current plugin's `Plugin.resources` table, below. A matching parameter type is not a documented cross-plugin permission.

The builtin-id overload is the other half of the map's split, and it does not need a Pack. A Listing stores a builtin id. `audio.Play` on an int keeps working after the plugin that offered the id is gone, because the id is not a plugin resource. A Clip is the resource overload, which is tied to the plugin that owns the file.

---

## What `Plugin.resources` is

https://d1s24e1pcksyf8.cloudfront.net/core/plugin.html#resources

"`Plugin.resources`: Table containing all custom resources stored under the current plugin's `resources` folder, using their filenames as table keys."

"Nested folders are represented as sub-tables, so for example `resources/images/menu/background.png` can be accessed as `Plugin.resources.images.menu.background`."

The example drops the extension. The key is the filename without its suffix, and each folder is a table. Applied to a Clip file at `resources/audio/some_name.ogg`, the documented shape is `Plugin.resources.audio.some_name`. The audio page's `Plugin.resources.click_long` is the same rule for a file sitting directly in `resources/`, not in a subfolder.

That table is the current plugin's folder. The plugin page's overview is "access and query properties for the current plugin, as well as access plugin resources." No page fetched here, and no hit in the docs search index, takes another plugin's name and returns that plugin's resources.

https://d1s24e1pcksyf8.cloudfront.net/core/plugin.html#plugin-resources

Supported custom resources:

- Sprites (`PluginResource` -> `PluginImageResource`): Portable Network Graphics (`.png`)
- Audio (`PluginResource` -> `PluginAudioResource`): Ogg Vorbis (`.ogg`)

A Clip has to be an `.ogg` file. A png is not an audio resource. `PluginAudioResource` is the audio specialization of `PluginResource`. The stub declares `PluginAudioResource` as an empty class (`runescape-api-stubs/types.lua:24`) and puts `path`, `loaded`, `inUse`, `Load`, and `Unload` on `PluginResource` (`generated/core/plugin.lua:29-41`). The live page is where the inheritance is written down.

### File name

A file name handed to Watchdog is a string. Strings can ride along in a normal call, but the string is only a key into whoever's `Plugin.resources` is in scope. Inside Watchdog, `Plugin` is Watchdog. The Pack's filename is not a key in Watchdog's table, and there is no documented function that opens the Pack's folder by name.

https://d1s24e1pcksyf8.cloudfront.net/tutorial/5database.html says the database "is separated per plugin, so that information saved by one plugin is not available to any other plugin." `PersistentDB` is not a side channel for the ogg bytes.

So a file name is not enough. Watchdog cannot play it.

### Resource object

Not established.

`audio.Play` will take a `PluginAudioResource`, and the Pack can read that object out of its own `Plugin.resources`. Getting it from the Pack's table into Watchdog's `audio.Play` is the step the docs never describe. Client API objects are userdata, not Lua tables (`D:\dev\rs3\.memory\api-data-is-userdata.md`). The dependency export example on the structure page is a table of functions, not a userdata value. Nothing says the clone of a returned table keeps a `PluginAudioResource`, and nothing says an argument of that type still works inside the other plugin's `audio.Play`.

Do not build the Clip handoff on the resource object. A probe could try it. This note is not that probe, and the pages are not a yes.

### Function that plays inside the Pack

This is the shape that matches the pages, with one hole.

The Pack can call `audio.Play(Plugin.resources.audio.some_name, params)` itself. That call uses the current plugin's resource, which is the only `audio.Play(PluginAudioResource)` pattern the audio page shows. For Watchdog's alert to trigger it later, Watchdog would have to hold something callable that the Pack passed in at registration, and call it when the alert fires.

The structure page does show calls from the dependent into the dependency, including arguments. It does not show a function created by the dependent being stored and called later by the dependency. That direction is not a documented capability. Details are in the next section.

---

## What actually crosses the plugin boundary

https://d1s24e1pcksyf8.cloudfront.net/structure.html#external-plugin-dependencies

A plugin sees another plugin only by listing it. Required and optional dependencies are both documented. The dependency "is then loaded before the current plugin, and its results are cloned (preventing dependants from modifying what's exposed by that dependency for other plugins) and exported to the current plugin, exposing them as a variable with the same name as the dependency."

The example dependency returns a table:

```lua
local lib = {}
function lib:Test() log("Hello World") end
return lib
```

The dependent calls `MyTestPlugin:Test()`. Optional dependencies may be absent: `if MyOptionalPlugin then`. An optional dependency changing at runtime fires global `PluginDependencyUpdate` (https://d1s24e1pcksyf8.cloudfront.net/structure.html#dependency-updates) with `pluginIdentifier` and `enabled`.

The same section then says: "Since exported tables are shared across any number of imports, if you need to provide per-plugin functionality in a library plugin, consider exporting instead functionality to create a stateful object which importers can pass in calls to your library, or which wraps the calls entirely. Similarly, importing plugins must not modify the contents of imports, as that would also affect other plugins."

Read those sentences as written. The page both says the result is cloned so other importers are protected, and says exported tables are shared so a mutation hits every importer. It does not say how deep the clone is, and it does not say what happens to userdata or to a function nested inside. The demonstrated call is the one in the example: the dependent invokes a function the dependency put on the returned table, and that function runs the dependency's body (`log("Hello World")`).

The "stateful object which importers can pass in calls" sentence is arguments flowing from the dependent back into the library. The object in that sentence is one the library's exported constructor created, not a `PluginAudioResource` and not a function the Pack wrote. Argument-passing exists. A whitelist of argument types does not.

Cyclical dependencies "are not allowed and will trigger an error." If the Pack depends on Watchdog, Watchdog cannot also depend on that Pack.

`require` does not cross plugins. The same page limits `require` to a path "relative to the plugin's root folder." The measured note agrees: each plugin is sandboxed to its own folder, and a sibling arrives only as an injected global when this plugin lists it under `requiredDependencies` or `dependencies` (`D:\dev\rs3\docs\agents\plugin-runtime.md`, the paragraph beginning "Each plugin is sandboxed to its own folder"). `D:\dev\rs3\.memory\rs3-plugin-dependency-model.md` records the same hard rule: an undeclared dependency's global is never visible, even if that plugin is loaded. That memory also says optional dependencies did not exist yet, as of 2026-07. The live structure page now documents `optionalDependencies` and `PluginDependencyUpdate`. The memory is stale on that point. The "not visible unless declared" part still matches the page.

Reload of a plugin wipes that plugin's Lua state (`D:\dev\rs3\.memory\plugin-reload-wipes-state.md`, and the same heading in `plugin-runtime.md`). Those notes do not measure whether two plugins share a Lua state, and they do not measure a userdata value after it has been passed across. This note does not invent a separate Lua VM, and it does not invent a shared one.

### Watchdog's exported table

Watchdog is the dependency. A Pack that lists it receives a clone of what Watchdog's script returns, under the global name `Watchdog` (folder name, or the alias key if the Pack uses the map form). Watchdog does not receive a global for the Pack, because Watchdog's manifest does not list one, and could not list every future Pack without a cycle.

On this branch's base (`origin/main`), `main.lua` builds `local api = {}`, assigns `Watchdog = api` (line 1013), and `return Watchdog` (line 1024). The functions on that table are `api.Stop` (line 929) and `api.Toggle` (line 955). The other fields are `editor`, `manager`, `mux`, and `document` (lines 965-968). There is no registration function. The local `main` checkout is nine commits ahead of `origin/main` and is not part of this branch; those same lines are the same there. Neither `plugin.json` lists a Pack.

The map on issue #120 already says the Pack calls the `Watchdog` global and Watchdog does not scan plugins. That matches this page. The registration function the Pack would call does not exist yet. Adding one is a Watchdog change, not a client capability.

### `SoundInstance` is the audio object the docs say can cross

https://d1s24e1pcksyf8.cloudfront.net/audio/index.html#audiostop

`audio.Stop(soundInstanceID)`: "Prefer using `audio.SoundInstance:Stop` instead whenever possible. The one advantage of using this function is it won't trigger an error if the sound instance is already defunct, so it can be useful if you're passing sound instances to other plugins."

That sentence is the client saying a `SoundInstance` is passed to another plugin. It is about an instance that already exists. It is not a way to start playback of someone else's file. The stub's `audio.Stop` (`generated/audio.lua:63-65`) stops at "if it exists and is live" and does not contain this sentence. The live page is the source for it.

The method and the function use different words for the dead instance. `audio.SoundInstance:Stop` "Does nothing if this sound has already expired." `audio.Stop` is the one that "won't trigger an error" on a defunct instance. The page does not define expired versus defunct. Quote both. Do not collapse them.

https://d1s24e1pcksyf8.cloudfront.net/audio/index.html#audiosoundinstance

"SoundInstances can also expire naturally (via shutdown of the plugin they were created in, or by being played and finishing), or through script requests (via `Stop`)."

"The plugin they were created in" is the plugin whose `audio.Play` returned the instance. The page does not say that creator can be a different plugin from the resource owner, because it never discusses playing someone else's resource.

`audio.StopSoundsUsingResource` also takes a `PluginAudioResource` (same audio page). It stops "all sound instances currently using the provided resource." It does not say the resource may belong to another plugin.

---

## What has to be true when the owner plays the file

This is the path the docs specify: the plugin whose `resources/` holds the ogg is the plugin that calls `audio.Play`. For a Clip, that plugin is the Pack. These conditions are from the plugin page and the audio page. They are not measurements from this session.

### Format and key

`.ogg` (Ogg Vorbis). Key: `Plugin.resources` plus one table per folder, then the filename without its extension. `resources/audio/some_name.ogg` is `Plugin.resources.audio.some_name`, by the nested-folder rule on the plugin page. The audio examples pass that object straight into `audio.Play`. They do not pass the string.

### `Load`

https://d1s24e1pcksyf8.cloudfront.net/core/plugin.html#plugin-resources

"Resources are automatically loaded on demand, or can be loaded explicitly by plugins, which can be useful when dealing with larger resources, or to keep audio in memory to avoid any delays."

`Load` is not a precondition of `audio.Play`. Play's nil return includes resource loading failing, so Play itself tries to load. Explicit `PluginResource:Load()` is how you pay that cost early. The audio sentence is why a Clip that must not hitch should be loaded before the alert fires, not because Play rejects an unloaded resource.

https://d1s24e1pcksyf8.cloudfront.net/core/plugin.html#load

`PluginResource:Load() -> PluginResourceLoadResult`

| Value | Meaning on the page |
| --- | --- |
| `success` | Loaded successfully. |
| `errorFilesystem` | Failed to read the resource from disk. |
| `errorDecode` | Failed to decode. Unsupported format is the reason the page gives. |
| `errorExceedsLimits` | Exceeds limits. The only numeric limit on the page is images at 1024x1024. No audio size limit is stated. |
| `errorConstruction` | Construct failed even though loading succeeded. "This can occur when attempting to load a resource during shutdown for example." |

The stub enum matches (`generated/core/plugin.lua:20-27`). Do not call `Load` from `PluginShutdown`. The page names shutdown as the `errorConstruction` case.

`Unload` "attempts to unload this resource's data." "No data is actually freed until all references to it have been released, meaning that if it's being used for a sprite elsewhere, that sprite will remain valid until it is removed as well, even though the resource itself has been unloaded." The only "still valid after Unload" example is a sprite. The page does not say a playing sound survives `Unload`. Do not assume a Clip does.

Properties, all read-only: `path` (disk path), `loaded` (data loaded and ready), `inUse` ("being used anywhere currently"). "Anywhere" is not defined as other plugins.

### How long it stays valid

"Once loaded, a resource will remain loaded until either the plugin that owns it is unloaded and all references to it are freed, or until the user manually unloads it."

The owner is the plugin whose `resources/` it came from. For a Clip, unloading the Pack is the first half of that sentence. The page does not say a reference held by Watchdog keeps the resource playable after the owner is gone. It also does not say playback keeps working across that unload. The map's rule that a Clip plays only while the Pack is loaded, and plays nothing when the Pack is missing, fits this sentence. It is not a promise that a borrowed reference outlives the Pack.

Separately, the `SoundInstance` expires when the plugin that created it shuts down, when playback finishes, or on `Stop`. If the Pack is the caller of `audio.Play`, both clocks are the Pack. A one-shot with `numLoops` 0 ends on its own. `numLoops` defaults to 0, "indicating a one-shot sound."

### Which bus

https://d1s24e1pcksyf8.cloudfront.net/audio/index.html#audiosoundplaybackparams

`audioBus` is `audio.AudioBus`. "Defaults to `audio.AudioBus.SFX`." Any value of that enum is a legal bus. The page does not reserve a bus for plugin resources.

| Name | Value |
| --- | --- |
| `MASTER` | 0 |
| `SFX` | 1 |
| `MUSIC` | 2 |
| `MUSIC_LOGIC` | 3 |
| `AMBIENT` | 4 |
| `VOICEOVER` | 5 |
| `SFX_SUB` | 6 |
| `MUSIC_SUB` | 7 |
| `DIALOG_SUB` | 8 |
| `PLAYER_ANIMATION_SUB` | 9 |
| `NPC_ANIMATION_SUB` | 10 |
| `LOCATION_ANIMATION_SUB` | 11 |
| `GENERAL_ANIMATION_SUB` | 12 |
| `LOCATIONS_SUB` | 13 |
| `LOCATION_RANDOM_SUB` | 14 |
| `LOCATION_GENERIC_SUB` | 15 |

The stub lists the same names and values (`generated/audio.lua:23-41`).

`volume` defaults to 1.0, "100% volume", relative to the bus. `type` defaults to `audio.SoundType.SCRIPT`. `SCRIPT` is a category: "Unless otherwise stated, these are just used to categorise sounds and don't affect playback." Two types do say otherwise. `MUSIC` and `JINGLE`: "Playback for audio of this type cannot be manually stopped." A Clip that must be stoppable should leave `type` at the default. Bus `MUSIC` and type `MUSIC` are different fields.

Other `SoundPlaybackParams` fields (`emitterShape`, distances, `origin`, `level`, `samplingRate`, `delayTick`) have defaults on the same table. Plugin audio does not require setting them. `emitterShape` defaults to non-spatial (`audio.EmitterShape.none` in the field text; the enum member on the page is `NONE`).

Playback starts immediately when params are omitted or `delayTick` is 0. The Play info box says you can defer with a large delay "and then manually calling `Play` on the created sound instance." The methods on `SoundInstance` are `Start`, `Stop`, `Pause`, and `Resume`. There is no `SoundInstance:Play` in the method list. The class blurb also says instances are "created dormant, and a plugin must then manually call `Play` on them." The Play function's own info box says the instance starts immediately when delay is 0. Those sentences disagree, and the info box names a method the page does not list. The stub exposes `Start` (`generated/audio.lua:81-83`) and the same "created dormant" blurb, without the "starts playing immediately" info box. Do not invent which name the client accepts for a deferred instance. Immediate playback with default params is the path both the examples and the Play info box describe, and it does not need that method.

---

## What Watchdog does today

This is plugin code, not a client rule.

On `origin/main`, Custom Sound is `nodes/actions/custom_sound.lua`. `resolveResource` (lines 5-9) returns `Plugin.resources.audio[name]` or nil. `run` (lines 60-75) calls `resource:Load()` through `preloadResource` (lines 12-19), builds `audio.SoundPlaybackParams`, sets `volume` to the pin divided by 100, sets `numLoops` from the pin, sets `audioBus` to `audio.AudioBus.SFX`, and calls `audio.Play(resource, params)`. The stored value is the table key, a string. The object passed to `audio.Play` is always Watchdog's own resource.

The local `main` checkout, nine commits ahead of `origin/main` and not on this branch, has the same node at `src/nodes/actions/custom_sound.lua`. Lookup and `audio.Play` are the same. The bus there is a dropdown (`MASTER`, `SFX`, `MUSIC`, `AMBIENT`, `VOICEOVER`) resolved against `audio.AudioBus`, default `SFX`. That dropdown is a Watchdog choice. The API accepts every bus in the table above.

Neither file has a path for a resource that belongs to another plugin. `Plugin.resources.audio` matches the live nested-folder rule for Watchdog's own `resources/audio/` files. The stub's `resources` field (`generated/core/plugin.lua:12`) stops at "filenames as table keys" and does not mention sub-tables, which is why a stub-only reading cannot explain the `.audio` key. The live info box does.

The code walks `Plugin.resources.audio` with `pairs` to fill the dropdown. The docs call `resources` a table and show key access. They do not mention `pairs`. This note does not add an in-client measurement of that walk.

---

## Stub lag that matters here

The live pages are ahead of `runescape-api-stubs/generated/`:

- Audio lives at `audio/index.html`. The stub file is still `generated/audio.lua`, from an older `audio.html` path.
- `Plugin.resources` nested folders and the dropped extension are on the live plugin page only.
- `PluginResource` -> `PluginAudioResource` for `.ogg` is on the live page. The stub's `PluginAudioResource` is an empty class.
- `audio.Stop`'s "passing sound instances to other plugins" sentence is not in the stub.
- `SoundInstance` expiring on shutdown of the creating plugin is not in the stub.
- Play's "starts playing immediately" info box is not in the stub. The stub only has the "created dormant" blurb.
- `trackingAccess` is a `PluginPermissions` value on the live plugin page. The stub enum has `httpAccess` and `chatAccess` only (`generated/core/plugin.lua:3-6`).
- `structure.html` (clone, `requiredDependencies`, `optionalDependencies`, `PluginDependencyUpdate`) is not generated into a stub. The generator skips narrative pages.

Where a stub and a live page disagree, this note follows the live page.

---

## What a later session can act on

Issue #125 has to name the fields of a Clip registration. The client facts above constrain them:

- Do not register a file name and have Watchdog pass it to `audio.Play`. Watchdog's `Plugin.resources` cannot see the Pack's file.
- Do not register the `PluginAudioResource` and have Watchdog pass it to `audio.Play`. The docs do not show that, and this session did not measure it.
- Do register by the Pack calling a function on the `Watchdog` table. That is the export the structure page specifies, and it is the direction issue #120 already settled. The function is not on the table today (`Stop` and `Toggle` only).
- The play call that the docs specify stays in the Pack: `audio.Play` on the Pack's own `Plugin.resources` entry, `.ogg`, optional `Load()` ahead of time, default bus `SFX` unless the alert's own bus pin says otherwise. The Pack does not ship volume, loops, or bus (issue #120). Those stay on the alert. `type` should stay `SCRIPT` so the instance can be stopped. Playback is specified only while the Pack is loaded.
- The hole: Watchdog's alert fires inside Watchdog, so something Watchdog calls has to end up in the Pack's `audio.Play`. A function argument stored at registration and called later is the obvious shape, and it is not in the docs. The structure page's arguments are state objects the library created. The audio page's cross-plugin object is a `SoundInstance` after play has started.

Before writing that callback into the contract as a fact, probe it in the client. The probe is small: a Pack lists Watchdog, Watchdog exports one function that stores a callback, the Pack passes a function that calls `audio.Play` on its own `Plugin.resources` entry, an alert invokes the callback, the sound is heard, and disabling the Pack makes the next invoke play nothing. If the stored function does not run against the Pack's `Plugin` global, the callback design is not available and the contract cannot pretend it is.

A second probe, only if someone still wants Watchdog to call `audio.Play` itself: pass the Pack's `PluginAudioResource` into that exported function and call `audio.Play` there. Success would be a measured extension past these pages. Failure is what the pages already allow. Do not ship the resource-object handoff on the docs alone.

`SoundInstance` handoff is already documented, and it is the wrong tool for starting a Clip. It is the right tool if, after the Pack has called `audio.Play`, Watchdog needs to stop that instance without erroring on a defunct object: keep the numeric `id` and call `audio.Stop(id)`.
