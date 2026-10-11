# The graph editor is drawn in immediate mode on a single ui.Canvas

The whole editor — every Node Body, Header, Pin Glyph, and Wire — is drawn onto one
`ui.Canvas`, `Clear()`-ed and fully rebuilt each `Event.Draw` frame through a View
(pan + zoom) transform the plugin owns. Nodes are *not* built from real interactive
components (`ui.Panel`/`ui.Button`/`ui.InputField`). We chose this because Canvas is the
only client primitive whose draw coordinates the plugin fully controls, which is what makes
continuous pan and zoom possible: real components position in fixed interface units with no
scale transform, so a component-per-node editor cannot zoom without recomputing every
component's pos/size/font each frame, fighting the layout engine.

## Consequences

Canvas drawables are inert, so input arrives through a visually empty Capture Layer.
It covers the content while idle and expands over the game window during a gesture.
Native click, hold, hover, release, drag-complete and scroll hooks feed manual hit-tests
against Nodes, Pins, and Wires. Canvas offers no rounded rectangle, circle, or bezier:
Node Bodies are square-cornered, Data Pin Glyphs are squares/diamonds, and Wires are
curves tessellated into straight `AddLine` segments.

Graph and resize gestures use native hook coordinates in interface units. The original
click selects the target and anchor; HOLD supplies movement; release supplies the final
position. The View applies canvas zoom. Comparing a queued hook with a newer raw mouse
poll can invent a scale change, so these paths do not poll or infer OS scale.

`CaptureInput` snapshots the capture origin before each Logic input batch, so expanding
capture during a click cannot change how queued coordinates are interpreted. A completed
click can deliver RELEASE before CLICK: retain its endpoint for the batch and finish the
click immediately when the native `isClicked` flag is false. Both release and drag-complete
end the gesture, and active capture stays above toolbar and resize controls.

Draw renders the latest delivered pointer; Logic owns double-click timing. Resize hooks
apply size changes directly, and unchanged bounds do not trigger layout writes. Native
hook delivery limits movement cadence. Alternate OS/interface scales, release outside
the client, drag-complete destination coordinates and visual smoothness still need native
validation. PrettyUI title dragging and other dependency controls retain their own scaling.
