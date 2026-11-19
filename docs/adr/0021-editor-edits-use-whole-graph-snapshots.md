# Editor edits use whole-graph snapshots

Copy, paste, and undo/redo share one plain-table copy of the graph, the Node Snapshot: nodes (type, Controls, name, Mode), the wires between them, and their Layout points.

Edit History keeps one Snapshot per step. Every few Logic ticks, while nothing is held and no field, popup, or Dialog is open, the Editor compares the graph with the last Snapshot and records any difference as one step. A drag, a typing session, or a paste is therefore one step, and no edit path has to record itself.

Undo edits the live graph in place, because the runtime runs that same graph object. Nodes that survive keep their id and runtime state. Nodes brought back get new ids, and an alias table maps the old id to the new one so older steps still find them.

## Considered options

Per-action commands with inverses. Rejected: every edit path would have to record itself, and a missed one silently breaks undo.

Replacing `editor.graph` with a deserialized copy. Rejected: the runtime would keep running the old graph.

## Consequences

- The graph is serialized every five Logic ticks while the Editor is open and idle.
- Nodes brought back by undo start with fresh runtime state. A deleted placeholder cannot be brought back.
- The shortcuts come from `Event.KeyDown`, which cannot consume a key, so the game gets them too. The Editor only acts on them with the cursor over its window.
