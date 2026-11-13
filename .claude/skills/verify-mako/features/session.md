# Session restore

Mako saves every trail to `trails.json` beside the config after every change: the whole tree of pages, the active page, collapsed rows, names, trail colours and the Undo Close stack. A crash or a forced quit loses nothing, and the next launch reopens it all. Only the active page loads at launch; the others load when selected. Addresses passed at launch, or opened from another app, are added as trails, or beneath the active page once the trail cap is reached. `restore_session = false` in the config starts empty, never writes `trails.json`, and deletes it when Mako quits. The first launch after the tabs era turns a `session.json` beside the config into trails. A `trails.json` Mako cannot read is kept aside as `trails.json.bad` and Mako starts empty. The sidebar width is kept separately, in Mako's preferences.

## Sub-features

- `session-save` every change rewrites `trails.json` at once; no quit is needed.
- `session-restore` launching reopens the same trees, active page, collapsed rows, names and colours; only the active page loads (`trails-bg` checks both).
- `session-undo` Reopen Closed Page works after a restart (`trails-ax` checks it).
- `session-plus-link` launching with an address restores the trails and adds the address as a trail, or beneath the active page at the cap.
- `session-off` `restore_session = false` starts with no page and the omnibox open, leaves `trails.json` untouched while Mako runs, and deletes it at quit.
- `session-migrate` with no `trails.json`, a tabs-era `session.json` (`{"tabs": [...], "active": n}`) becomes one trail per tab (pages beneath the last trail past the cap), with the active tab's page selected.
- `session-bad` an unreadable `trails.json` is renamed `trails.json.bad`, logged as `trails.json rejected: <why>`, and Mako starts empty.

## How to get to it (user POV)

- Quit with ⌘Q (or close the window), or have Mako killed, then open it again.
- Open a link in Mako while it is not running.
- Add `restore_session = false` to the config (⌘,).

## Driving it with makoctl

Preconditions: baseline; `MAKO_BACKGROUND=1` is fine except where marked. Serve the trail fixtures (`.claude/skills/verify-mako/scripts/fixture-server $PORT &`, `U=http://127.0.0.1:$PORT`) and launch with `$C launch "" "$U/c.html"`. `J=verify-runs/latest/state/trails.json`. `omni() { $M $P menu File "$1"; sleep 0.3; $M $P set mako.omnibox.field "$2"; $M $P confirm mako.omnibox.field; sleep 1.5; }`.

- **Save on change.** `omni "New Trail" "$U/c.html?two"; $M $P press-id mako.trail.1; omni "New Page in Trail" "$U/h.html"`. Right away, with no quit, `python3 -m json.tool $J` shows roots `[1, 2]`, page 3 (`h.html`) under page 1, and `"active": 3`.
- **Kill and restore.** `cp $J $E/before-kill.json; kill -9 $P; $C relaunch; P=$($C pid)`. `wait-title "Page H"`; `menu-items Trails` stars `Page H`; `cmp $J $E/before-kill.json` succeeds.
- **Lazy load.** `log show --info --last 1m --predicate "processID == $P AND subsystem == \"com.wego.mako\"" --style compact` has `allow $U/h.html` and no `allow` line for `c.html`.
- **Restore plus a link.** `$C quit; $C relaunch "$U/c.html?three"; P=$($C pid)`. A third root, active. Again with `?four`: at the cap, a page beneath the active page instead.
- **Off.** `echo 'restore_session = false' >> verify-runs/latest/state/config; cp $J $E/before-off.json; $C quit; $C relaunch; P=$($C pid)`. `title` is `Mako`, `exists mako.blank` exits 0, `value mako.omnibox.status` says `0 trails, 0 pages`. `omni "New Trail" "$U/c.html"`, then `cmp $J $E/before-off.json` still succeeds. **(focus)** `$C quit` without `MAKO_BACKGROUND`: `$J` no longer exists.
- **Migrate.** `$C stop; $C launch; $C quit` (fresh state, no `trails.json`), then `printf '{"tabs":["%s","%s"],"active":1}\n' "$U/c.html" "$U/h.html" > verify-runs/latest/state/session.json` and `$C relaunch; P=$($C pid)`. `trails.json` has two roots, the `h.html` one active; `wait-title "Page H"`.
- **Unreadable file.** `$C quit; echo 'not json' > $J; $C relaunch; P=$($C pid)`. `title` is `Mako`; `verify-runs/latest/state/trails.json.bad` holds `not json`; the log has `trails.json rejected:`.
- **Proof.** `trails.json` copies before and after each step, `title` and `menu-items Trails` after each relaunch, and `shot $E/session-restored.png` after the restore.

## Gotchas

- `$C stop` kills the process and wipes the state dir; use `kill -9` or `$C quit`, then `$C relaunch`.
- With `MAKO_BACKGROUND=1`, `$C quit` is SIGTERM, which skips `applicationWillTerminate`, so the **Off** step's deletion at quit needs a headed quit.
- A relaunch loads the active page. A fixture that clicks its own links (`a.html`, `b.html`) opens new children on every load; use `c.html` and `h.html` here.
- A JSON reader may reorder keys; compare values, or `cmp` the file only right after a restart, before anything changes.
- A config that fails to parse falls back to defaults, so restore stays on.
- The sidebar width survives `quit` and `relaunch` within a run; `stop` wipes it with the run's preferences.
