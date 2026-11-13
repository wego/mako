# Navigation and zoom

Back, forward, reload and page zoom, from the History and View menus or their shortcuts, without toolbar buttons. They act on the shown page's own history: going back changes that page in place, it never selects another page. The shortcuts go to the page first, so a web app that handles one of them keeps it. Back, Forward and Reload count as navigations the person started, which is what lifts a page's dialog silencing (`features/dialogs.md`).

## Sub-features

- `nav-back-forward` ⌘[ and ⌘] (History → Back, Forward) or a two-finger swipe move through the page's history; its sidebar row follows the page's address and title.
- `nav-reload` ⌘R (View → Reload) reloads the page.
- `nav-zoom` ⌘=, ⌘-, ⌘0 (View → Zoom In, Zoom Out, Actual Size) zoom in, out, and reset, in 0.1 steps with a 0.3 floor and no ceiling; pinch magnifies too. Zoom belongs to the page's web view: other pages keep their own, and it is lost when the view is unloaded (the page closed, eight other pages shown since, or a restart).

## How to get to it (user POV)

- History → Back / Forward, or ⌘[ / ⌘].
- View → Reload, Zoom In, Zoom Out, Actual Size, or ⌘R / ⌘= / ⌘- / ⌘0.
- Two-finger swipe for back/forward; pinch to zoom.

## Driving it with makoctl

Preconditions: baseline; `MAKO_BACKGROUND=1` is fine except for the key steps. Serve the trail fixtures (`.claude/skills/verify-mako/scripts/fixture-server $PORT &`, `U=http://127.0.0.1:$PORT`) and launch with `$C launch "" "$U/c.html"`. `go() { $M $P menu File "Open Location…"; sleep 0.3; $M $P set mako.omnibox.field "$1"; $M $P confirm mako.omnibox.field; }`.

- **History.** `go "$U/h.html"; $M $P wait-title "Page H"`. `trails.json` still holds one page, now at `h.html`. `$M $P menu History Back` then `wait-title "Page C"`; `$M $P menu History Forward` then `wait-title "Page H"`. **(focus)** `key "cmd+["` and `key "cmd+]"` do the same.
- **Reload.** Start `log stream --level info --predicate 'subsystem == "com.wego.mako"' --style compact > $E/reload-log.txt &`, then `$M $P menu View Reload`. A new `loaded page 1: Page H` line appears. **(focus)** `key cmd+r`.
- **Zoom.** `$M $P shot $E/zoom-1.png; $M $P menu View "Zoom In"; $M $P menu View "Zoom In"; sleep 0.8; $M $P shot $E/zoom-2.png; $M $P menu View "Actual Size"`. `cmp` says the shots differ, and the text in `zoom-2.png` is visibly larger. **(focus)** `key "cmd+="`, `key "cmd+-"`, `key cmd+0`.
- **Proof.** Titles after each step, the log lines, both shots.

## Gotchas

- Swipe and pinch gestures can't be posted with makoctl; only the menu and key entry points are drivable.
- Zoom is not saved with the trails.
- In-page navigation that a page starts itself (a `#fragment` jump, a form submit, a redirect) is covered by `trails-bg`.
