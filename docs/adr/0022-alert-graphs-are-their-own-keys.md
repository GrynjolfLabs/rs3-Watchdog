# Alert graphs are their own keys

A PersistentDB value caps at 131070 bytes. One scope document holds every alert graph, so a scope of about 50 alerts fills the key. `SetString` then returns false and leaves the previous bytes, and `Store.SaveTo` treats that as success. The scope key will keep the tree. Each alert's graph and layout get their own key, compressed. The same split applies to the preset library. Not landed.

## Considered options

Keep one document and chunk it, or only compress it. Rejected. A chunk still rewrites every graph to save one, and compression alone meets the same cap later. Compression is in addition to the split: every new scope, alert, and preset value is a `WD1` token. The cap is the length of that token. Notices, the toast anchor, the transfer note, and the legacy keys stay plain strings.

Overwrite `global`, `player_<tracking id>`, and `presets` with the slim documents. Rejected. Those keys are the pre-migration snapshot. Nothing writes or deletes them. There is no restore control.

Write an empty string, or delete the scope key, when the tree is empty. Rejected. An absent new key means "migrate from the legacy key." An empty tree is a real document, so a later startup does not put the deleted alerts back.

## Consequences

The runtime still calls a scope `global` or `player_<tracking id>`. The store maps those to `scope_global` and `scope_player_<tracking id>`. Alert keys are `scope_global_alert_<id>` and `scope_player_<tracking id>_alert_<id>`. The preset index is `scope_presets`. Each preset is `scope_presets_<id>`. Same entry id in two scopes stays two keys.

Startup lists the plugin's keys and migrates `global`, `presets`, and every `player_<digits>` key whose new key is absent. Tracking permission is not required, and the player does not have to be logged in. A non-numeric `player_*` key stays unread. If listing keys fails, `global` and `presets` still migrate, and the current character migrates in the bucket loader once the id is known. Disk migration of a key finishes before that scope is armed. A failed migration of a character who is not loaded is a log line. The load that arms that character shows a message dialog and still uses the legacy document. One scope failing does not stop another.

A scope migrates all at once. Alert keys are written first. The new scope key is written only after every one of those tokens is stored. If one token is over the cap, the size dialog names that alert, the new key stays absent, and the legacy key is not written. Quitting drops the in-memory edits. A scope that contains an alert which cannot be shrunk under the cap does not finish migration.

`SaveAlert` takes the scope identity and that alert and writes only that alert key. `SaveScope` writes the index and does not walk graphs. Create, import, and a move call `SaveAlert` for each alert they changed, then `SaveScope`. `SavePreset` writes that preset key. A library-list change writes the preset index. A repeat save of the same payload writes again. The infobox anchor stays on `scope_global`.

`SaveScope` omits graph and layout. It still writes when the tree is empty. `scope_global`, `scope_player_<tracking id>`, and `scope_presets` are never deleted and never set to an empty string. That empty write happens only after this session read the scope successfully, or after a legacy document that really had no alerts.

Document versions are inside the JSON, after `WD1` is removed. A new scope document is version 3: the tree, plus the infobox anchor on the global scope. The preset index is version 2: id, name, and variables. An alert key and a preset key are version 1: `version`, `graph`, and `layout`. The graph keeps its own version. `WD1` is the token layout. A tree-shape change bumps the document version and stays `WD1`. A change to the deflate or base64 layout becomes `WD2`.

`scope_global` and `scope_player_<tracking id>` load only at version 3. `scope_presets` loads only at version 2. An alert or preset key loads only at version 1. Any other version, including a missing one, stays on disk and is not rewritten. Legacy `global`, `player_<digits>`, and `presets` keep their current readers. A version-3 entry that still has a graph or layout inline ignores those fields and uses the alert key.

Armed scopes still load every alert graph. A missing or unreadable alert key leaves the row in place, unarmed, and the editor does not open it. A load dialog names it. Orphan keys the index does not name are ignored and left on disk.

`SetString` counts as saved only when it returns true. False, nil, and a throw leave the previous bytes. `Delete` counts only when it returns true. A token longer than 131070 bytes is refused before `SetString`, and a message dialog says that alert is too big to save. The in-memory graph stays. The previous key stays. The same dialog covers a preset and a scope key that itself does not fit. The dialog shows once while that alert stays open, and a successful save clears the flag. Closing the alert clears it too. Nothing about the dialog is stored. A preset save, and a scope key that does not fit, show the dialog on every failed save. A failed save under the cap shows a message dialog that does not call it a size failure. A failed enable that is not a size refusal stays the ADR 0015 log line. A failed write of the toast anchor, seen notices, or the transfer note is a log line. Notices still count a failed mark as seen until the plugin unloads.

Removing an alert writes the scope key without that entry first, then `PersistentDB:Delete` on the alert key. A failed scope write leaves the alert key in place. A create or a move writes the destination alert key first, then the scope key that points at it, and deletes the source key only after the destination scope key is written. A crash can leave an orphan key, or the same alert in both scopes. It cannot leave a tree entry whose graph was already deleted.

When a new scope key or `scope_presets` exists but cannot be read, one message dialog reports it, this session uses an empty tree, and nothing writes that key. The legacy key is not read. Save, create, delete, import, move, and enable for that scope are refused. Other scopes still load and save. A missing new key still migrates.
