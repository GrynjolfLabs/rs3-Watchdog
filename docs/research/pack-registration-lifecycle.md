# Pack registration lifecycle (wayfinder ticket #122)

## The question

A Pack registers by calling the Watchdog global while the Pack is loaded. Watchdog does
not persist that registry, and Watchdog runs with zero Packs.

What does the client actually do on load, reload, and disable?

- Does listing Watchdog in the Pack's `requiredDependencies` guarantee that Watchdog's
  `main.lua` has finished, and the `Watchdog` global exists, before the Pack's
  `main.lua` runs?
- If Watchdog is reloaded, do Packs that depend on it reload too? Or does Watchdog come
  back with an empty registry and no second registration call?
- If a Pack is disabled or reloaded, does Watchdog observe that, or can the Pack
  unregister only from its own `PluginShutdown`?
- Could an optional dependency let a Pack load while Watchdog is absent? The contract
  wants Packs to require Watchdog. Confirm whether required is the relationship that
  matches that.

This note records lifecycle facts. It does not design the registration API.

Sources consulted, in priority order:

1. Authoritative docs site, fetched for this note:
   - https://d1s24e1pcksyf8.cloudfront.net/structure.html
   - https://d1s24e1pcksyf8.cloudfront.net/managing.html
   - https://d1s24e1pcksyf8.cloudfront.net/core/events.html
   - https://d1s24e1pcksyf8.cloudfront.net/tutorial/1helloworld.html
   - https://d1s24e1pcksyf8.cloudfront.net/core/plugin.html
2. Local stubs at `D:\dev\rs3\runescape-api-stubs` (cross-check only).
3. Measured runtime notes: `D:\dev\rs3\docs\agents\plugin-runtime.md`,
   `D:\dev\rs3\.memory\plugin-reload-wipes-state.md`, and
   `Watchdog/docs/adr/0008-pluginshutdown-is-the-teardown-hook.md`.
4. Watchdog on this branch's base (`origin/main`, `c1eda82`): `main.lua`, `plugin.json`.

**The docs site was accessible.** Dependency load order, the required/optional split, and
`plugins_reload` are documented only. `PluginShutdown` and the per-plugin Lua wipe are
measured in-client and recorded in ADR-0008; they were not re-run for this ticket. No
source here measures a Pack and Watchdog reloading against each other. Those gaps are
called out below.

`D:\dev\rs3\.memory\rs3-plugin-dependency-model.md` (dated 2026-07) says dependencies are
hard-only and that optional dependencies did not exist yet. The live structure page now
documents `optionalDependencies` and `PluginDependencyUpdate`. That memory is stale on
those two points. Its claim that an undeclared plugin's global is never injected still
matches the structure page and the runtime note.

---

## What "the Watchdog global" is

**Documented, not re-measured here.** `structure.html` (External Plugin Dependencies)
says a dependency "is then loaded before the current plugin, and its results are cloned
(preventing dependants from modifying what's exposed by that dependency for other
plugins) and exported to the current plugin, exposing them as a variable with the same
name as the dependency." The dependency example is a `main.lua` that builds a table and
`return`s it. The dependent then calls `MyTestPlugin:Test()`.

**Code.** On `origin/main`, Watchdog's `main.lua` builds `local api = {}`, defines
`api.Stop` (line 929) and `api.Toggle` (line 955), assigns `api.editor`, `api.manager`,
`api.mux`, and `api.document` (lines 965-968), then:

```lua
Watchdog = api
-- ...
return Watchdog
```

(`main.lua:1013` and `main.lua:1024`). There is no registration function on `api`.

So the global a Pack receives is the **cloned return value** of Watchdog's script,
exported under the name `Watchdog` (the plugin folder), unless the Pack aliases it.
It is not a view into Watchdog's own Lua global. The runtime note says each plugin is
sandboxed to its own folder, and a sibling arrives only as an injected global
(`D:\dev\rs3\docs\agents\plugin-runtime.md`, the paragraph beginning "Each plugin is
sandboxed"). That note does not mention the clone. The clone is docs-only.

The same page warns: "exported tables are shared across any number of imports" and
"importing plugins must not modify the contents of imports, as that would also affect
other plugins." The pages do not say whether the clone is deep, whether Watchdog's
local `api` stays the same object as the export, or whether a field the Pack writes
onto its `Watchdog` table shows up in Watchdog. They do show that calling a method on
the export runs the function the dependency defined. A registration call has to be a
function Watchdog put on the returned table. Assigning fields on the export is the
thing the warning tells importers not to do.

`require` does not cross plugins. The structure page limits `require` to a path
"relative to the plugin's root folder." The runtime note agrees.

---

## Does `requiredDependencies` finish Watchdog before the Pack runs?

**On the documented success path, yes. Not measured in-client for this ticket.**

`structure.html` overview: `main.lua` is the "Lua script to execute when enabling the
plugin." `tutorial/1helloworld.html`: `pon <plugin>` runs that script (the tutorial's
`print("Hello world!")` appears when the plugin is enabled).

External Plugin Dependencies then says the dependency is loaded **before** the current
plugin, and that its **results** are cloned and exported as a global before the
dependent's script uses them. The required example calls `MyTestPlugin:Test()` with no
nil check. The optional example is the one wrapped in `if MyOptionalPlugin then`.

Watchdog's script returns only after `Watchdog = api` (`main.lua:1013` then
`main.lua:1024`). A Pack that lists Watchdog under `requiredDependencies` and actually
gets as far as running `main.lua` is, on this documented path, running after Watchdog's
script has produced that return value. The Pack's `Watchdog` global is the export of
that value, so it exists at the start of the Pack script. The folder name `Watchdog` is
a legal Lua identifier, so the export name is `Watchdog` unless the Pack aliases it
(`"requiredDependencies": { "SomeName": "Watchdog" }` maps variable name to plugin
name, same page).

The runtime note says the same load-first rule for `requiredDependencies` (or the older
`dependencies` field): "the client loads those first and exposes" the global. It does
not cite a probe journal. Treat it as agreement with the docs, not as a new measurement.

**Not proven:**

- The pages never say the client refuses to enable a plugin whose required dependency
  is missing, disabled, or failed while loading. "Required" plus an unconditional call
  is the documented success path. The failure mode is not written down.
- They do not say the Pack and Watchdog share one table. They say the result is cloned.
- A name that cannot be a Lua identifier is rewritten with `_` (the page's example is
  `2!GraphLib` becoming `_2_GraphLib`). `Watchdog` does not need that rewrite.

Cyclical dependencies "are not allowed and will trigger an error" (`structure.html`,
Dependencies). The example is `A depends on B depends on A`. The page does not limit
that to `requiredDependencies`. Watchdog's `plugin.json` lists no Pack. Listing one,
while that Pack lists Watchdog, is the cycle the page forbids. That is documented, and
it matches the contract's "Watchdog never depends on a Pack." It was not measured here.

---

## If Watchdog is reloaded, do Packs reload?

**Watchdog itself comes back empty. A second registration call from Packs is not
proven, and neither is a cascade that reloads them.**

**Documented.** `managing.html`: `plugins_reload <plugin>` (`prl`) "Reloads the
specified plugin. This simply disables and then re-enables a plugin."
`tutorial/1helloworld.html` says reload is "equivalent to turning it off and on again"
and that reload runs that plugin's script again. Both descriptions name one plugin.
Neither says dependents are disabled or re-enabled.

**Measured in-client** (ADR-0008, probe journal in `PluginData.db`, three reload
cycles; not re-run for this ticket). Reloading a plugin calls that plugin's
`PluginShutdown`, discards its Lua state, then loads a new instance. The new instance
sees the old global as nil. The re-execution guard at the top of the script does not
fire, because there is nothing left in that state. `plugin-reload-wipes-state.md`
records the same fact: globals, the `require` cache, locals, and listeners from the
old copy are gone; `PluginShutdown` runs before the wipe; the new script starts empty.
`plugin-runtime.md` (Lifecycle) repeats that measured note.

**Code, on top of that wipe.** The new `main.lua` builds a fresh `local api = {}` and
assigns `Watchdog = api` at the end. `persistNow` (`main.lua:799-808`) writes the bound
alert document through `Store.UpdateAlertGraph` and `Store.SaveTo`. `PluginShutdown`
(`main.lua:1017-1022`) calls `persistNow`, `HubLayers.Unbind()`, and `ribbon:Destroy()`.
Nothing in that path reads or writes a Pack list. There is no registration API, so a
fresh Watchdog process image has an empty registry because the Lua state was wiped and
the script never rebuilds one. That emptiness is measured wipe plus this code, not a
Pack-reload experiment.

**What the docs do say about a dependency changing under a plugin that stays loaded.**
Only optional dependencies. `structure.html` (Dependency Updates): "whether or not
optional dependencies are enabled can change while a plugin is running", and the
already-running plugin's global `PluginDependencyUpdate` is called. The example sets a
local flag. It does not re-run `main.lua`. `core/events.html` (`OptionalDependencyChanged`):
"Called when an optional dependency plugin is enabled or disabled. This event is only
sent to plugins which have registered the changing plugin as an optional dependency."
Payload fields are `pluginIdentifier` (String) and `enabled` (Boolean). The same text
is in the stub at `runescape-api-stubs/generated/core/events.lua:45-49`, and the `Event`
field is at line 317. The structure page says `PluginDependencyUpdate` "is automatically
converted into" that event. No discrepancy.

That callback is the **dependent** observing an **optional** dependency. It is not sent
to the dependency. A Pack that lists Watchdog as required does not get it. A Pack that
lists Watchdog as optional would get `enabled` / `disabled` while the Pack keeps
running. Watchdog's own handler (`main.lua:113-119`) only reacts to `LibPluginMenu`.
That is Watchdog using the optional-dependency callback, which is consistent with the
docs, and it is not a measurement that Packs stay loaded when Watchdog reloads.

**Not proven, and not to be filled in:**

- Whether `plugins_reload Watchdog` also reloads or disables Packs that require it.
- Whether an export cloned at Pack load still calls into the new Watchdog instance,
  calls into the dead one, or becomes nil.
- Whether a required dependency being disabled forces the dependent off. No page
  documents a required-dependency callback at all.

The contract cannot assume Packs register a second time. It also cannot assume the
client promises they will not. These sources only show that Watchdog's own state is
empty after its own reload.

---

## If a Pack is disabled or reloaded, does Watchdog observe it?

**No documented observer, and Watchdog's script has none. The Pack can still call
during its own `PluginShutdown`. That cross-plugin call was not measured.**

**Measured in-client** (ADR-0008 table; not re-run here). The client calls global
`PluginShutdown()` with no arguments on the plugin being torn down:

| Trigger | `PluginShutdown` fires | New instance loads |
|---|---|---|
| `poff <plugin>` (disable) | yes | no |
| `pon <plugin>` (enable) | - | yes |
| `plugins_reload <plugin>` | yes | yes, after |
| Clean client exit | yes | - |
| Client crash | no | - |

`PersistentDB` writes from inside the hook were accepted. `:Destroy()` on a UI
component from inside it crashes the client. The hook is absent from the stubs and from
the dependency and lifecycle pages above. `core/plugin.html` mentions shutdown only as
`PluginResourceLoadResult.errorConstruction`: loading a resource "can occur when
attempting to load a resource during shutdown." That names a shutdown phase. It does
not document `PluginShutdown`. The stub enum matches
(`runescape-api-stubs/generated/core/plugin.lua:20-27`).

The probe measured the plugin that was disabled or reloaded. It did not measure a
second plugin watching that one.

**Documented direction of the only lifecycle callback.** `OptionalDependencyChanged`
goes to the plugin that **declared** the changing plugin as an optional dependency
(`core/events.html`). Watchdog's `plugin.json` required set is `LibNodeGraph`,
`LibNodeGraphStd`, and `prettyui`. Its optional set is `LibPluginMenu` and
`shortestpath`. No Pack is listed. Nothing in that manifest subscribes Watchdog to a
Pack's enable or disable. The handler that does exist watches `LibPluginMenu` only.

**Measured timing of the Pack's own hook.** `plugin-reload-wipes-state.md`: the client
calls `PluginShutdown` on disable, reload, and clean exit, **before** that plugin's
state is wiped. So the Pack's `PluginShutdown` still runs inside the Pack's Lua state.
That is the last moment the Pack can execute. After it returns, that state is gone
(measured). On a crash it never runs (measured). The injected `Watchdog` export was
not separately probed inside `PluginShutdown`; the measured claim is that the shutting
down plugin's state is still alive for the call. A call from that function is the only
hook these sources give the Pack.

**Inference, not a direct measurement.** Reload and disable name one plugin
(`managing.html`), and the wipe is of that plugin (ADR-0008). Reloading or disabling
the Pack therefore leaves Watchdog's Lua state in place. If a registration had mutated
state inside Watchdog, Watchdog would still hold it, and Watchdog would not be told to
drop it. The Pack's new `main.lua` after a reload would be a second registration on
top of that state unless the Pack's `PluginShutdown` had already called Watchdog to
remove the first. This investigation did not run that pair of plugins.

Watchdog will not discover the gap on its own. It does not scan plugins (no such call
in `main.lua`), and it does not persist a pack registry (`persistNow` saves the bound
alert document only).

---

## Is required the relationship that matches the contract?

**Yes. Optional is the relationship that allows the Pack to load while Watchdog is
absent. Documented, not re-measured here.**

`structure.html`: "You can define both required and optional dependencies, with the
latter allowing you to provide additional functionality once those dependencies are
available and enabled." The example manifest is:

```json
"requiredDependencies": [ "MyTestPlugin" ],
"optionalDependencies": [ "MyOptionalPlugin" ]
```

The required global is called with no check. The optional global is used only inside
`if MyOptionalPlugin then`, and its later enable/disable is `PluginDependencyUpdate` /
`OptionalDependencyChanged` (docs and stub, cited above). Watchdog already treats
`shortestpath` that way: `nodes/actions/shortest_path.lua` starts from
`shortestpath ~= nil` and updates a flag from `OptionalDependencyChanged` (lines
17-29). That is local code following the documented optional model. The comment there
says the flag flips without reloading Watchdog. The comment is not a probe log; the
docs' in-place flag example is the source for "the dependent keeps running."

So:

- `requiredDependencies` is the field that matches "a Pack requires Watchdog" and, on
  the success path above, "Watchdog's script has returned and the export exists before
  the Pack script runs."
- `optionalDependencies` is the field that matches "the Pack may load with Watchdog
  absent, and learn later that Watchdog came or went." That contradicts the contract.

The manifest field table on the same page still documents an older `dependencies`
field (`[String]` or `{ String -> String }`, variable name to plugin name). The
external-dependency section is the one that introduces `requiredDependencies` and
`optionalDependencies`. The pages do not say `dependencies` is an alias of
`requiredDependencies`. Watchdog's own manifest uses the required and optional keys
(`plugin.json`). The runtime note's "loads those first" sentence names
`requiredDependencies` (or `dependencies`), not `optionalDependencies`.

The hard "plugin will not enable if a required dependency is missing" sentence is
**not** on these pages. Do not treat it as proven. What is proven from the docs is the
split above: required is loaded first and called unconditionally in the example;
optional is allowed to be nil.

---

## What a later session can use

1. A Pack lists Watchdog under `requiredDependencies`, not `optionalDependencies`.
   On the documented success path the Pack's `main.lua` starts after Watchdog's script
   has returned, and the Pack's `Watchdog` global is the clone of that return value.
2. Registration has to be a call on that export. The docs say the result is cloned and
   tell importers not to modify the imported table. They do not say a field written by
   the Pack lands in Watchdog's `local api`.
3. After Watchdog reloads, Watchdog's Lua state is empty and nothing in `persistNow`
   restores Packs. These sources do not show Pack `main.lua` running again. Do not
   assume a second registration, and do not assume the old export still reaches the
   new instance.
4. Watchdog does not observe Pack disable or reload. The Pack's `PluginShutdown` is
   the measured hook that still runs in the Pack, before that Pack's state is wiped,
   on disable, reload, and clean exit. It does not run on a crash. Unregister belongs
   there if the registration mutated Watchdog, because Watchdog's state stays up
   across a Pack reload (inference from the per-plugin command and the per-plugin
   wipe, not a paired measurement).
5. Watchdog must not list the Pack. A cycle is a documented error, and Watchdog's
   manifest on `origin/main` lists none.
