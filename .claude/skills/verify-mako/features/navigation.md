# Navigation and zoom

Standard page controls without toolbar buttons: back, forward, reload, and page zoom, from the History and View menus or their shortcuts. These go to the page first, so a web app that handles one of them keeps it.

## Sub-features

- `nav-back-forward` ⌘[ and ⌘] move through the tab's history.
- `nav-reload` ⌘R reloads the page.
- `nav-zoom` ⌘=, ⌘-, ⌘0 zoom in, out, and reset, in 0.1 steps with a 0.3 floor and no ceiling; pinch also zooms.

## How to get to it (user POV)

- History → Back / Forward, or ⌘[ / ⌘].
- View → Reload, Zoom In, Zoom Out, Actual Size, or ⌘R / ⌘= / ⌘- / ⌘0.
- Two-finger swipe for back/forward; pinch to zoom.

## Driving it with makoctl

Preconditions: baseline launched with `https://example.com`.

- **History.** `$M $P key cmd+l; $M $P type iana.org; $M $P key return; $M $P wait-title "Internet Assigned" 8`. `$M $P key cmd+[` then `wait-title "Example Domain"`. `$M $P key cmd+]` then `wait-title "Internet Assigned"`.
- **Menus.** `$M $P menu History Back` then `wait-title "Example Domain"`; `$M $P menu History Forward` returns.
- **Reload.** Run `log stream` filtered to `com.chuyeow.mako`, then `$M $P key cmd+r`. A new `loaded tab 0/1` line appears.
- **Zoom.** `$M $P shot $E/zoom-1.png; $M $P key cmd+=; $M $P key cmd+=; $M $P shot $E/zoom-2.png; $M $P key cmd+0`. Text in `zoom-2.png` is visibly larger than in `zoom-1.png`.

## Gotchas

- Swipe gestures can't be posted with makoctl; only the menu and key entry points are drivable.
- Zoom is per tab and isn't saved by session restore.
