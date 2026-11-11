# Screen Flash counts cycles

Screen Flash's lifetime is a cycle count, not Hold. Hold stays a number of seconds on Toast, Popup, Screen Marker, and Object Marker. One cycle is the rise segment followed by the fall segment. Rise and Fall are their own inputs, in seconds. Sticky ignores the count and repeats until Dismiss. A saved Screen Flash with no Sticky value loads sticky, so an existing flash keeps looping.

## Considered options

Give Screen Flash a Hold pin in seconds, like Toast. Rejected. The effect is a rise and a fall, and the useful control is how many of those pairs play. A seconds cap would cut a pair at a wall-clock time that ignores the shape of the flash.
