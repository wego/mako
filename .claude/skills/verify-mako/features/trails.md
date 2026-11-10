# Trails

Trails replace tabs. A trail is a tree of pages in the sidebar: a followed link opens as a new page beneath the page it came from. Up to `max_trails` (default 2) trails exist at once; pages within a trail are unlimited. Trails, and the stack of closed pages, are saved after every change and come back at launch.

## Sub-features

- `trail-link` a clicked link (including `target=_blank`) opens a child page and selects it.
- `trail-in-place` a `#fragment` jump, form submit, redirect, or ⌘L address changes the current page; no new page.
- `trail-new` ⌘T starts a trail; refused at the cap with a message in `mako.omnibox.status`.
- `trail-child` ⌥⌘T opens a page beneath the current one from the omnibox.
- `trail-external` a link from another app starts a trail, or at the cap opens beneath the current page.
- `trail-select` a sidebar row, a Trails menu item, or ⌃Tab / ⌃⇧Tab selects a page.
- `trail-close` ⌘W closes the active page and everything beneath it; a neighbour becomes active.
- `trail-undo` ⇧⌘T reopens the last closed page with its subtree where it was, also after a restart.
- `trail-collapse` a row's toggle hides or shows the pages beneath it.
- `trail-restore` quitting and reopening shows the same tree and active page; only the active page loads.
- `trail-blocked-link` a link to a blocked host opens a child page showing the block notice.

## How to get to it (user POV)

- Click a link on a page.
- File → New Trail (⌘T), New Page in Trail (⌥⌘T), Close Page (⌘W), Reopen Closed Page (⇧⌘T).
- Click a row or its toggle in the sidebar; Trails menu; ⌃Tab.
- Open a link from another app.

## Driving it with makoctl

Preconditions: baseline. For background runs set `MAKO_BACKGROUND=1` (then use `menu`, `press-id`, `set`, `confirm`; no `key`/`type`). Fixture pages that click their own links are in `fixtures/trails/`; serve them with `python3 -m http.server $PORT --bind 127.0.0.1 -d .claude/skills/verify-mako/fixtures/trails &`.

- **No permissions, no focus.** `.claude/skills/verify-mako/scripts/trails-bg` covers `trail-link`, `trail-in-place`, `trail-external`, `trail-restore` and `trail-blocked-link` by reading `trails.json` and the log. 15 checks, proven.
- **Link.** Launch on `$U/a.html`. `$M $P menu-items Trails` lists `Page A`, `Page B`, `Page C` with `Page C` checked; `python3 -m json.tool verify-runs/latest/state/trails.json` shows page 3 under 2 under 1.
- **New trail and cap.** `$M $P menu File "New Trail"; $M $P set mako.omnibox.field example.com; $M $P confirm mako.omnibox.field`. A second root appears. Repeat: `value mako.omnibox.status` starts `Can’t open: trail cap reached (2)`.
- **Select.** `$M $P press-id mako.trail.1`. `title` is `Page A`; `value mako.trail.1` is `selected`.
- **Close and undo.** `$M $P menu File "Close Page"` removes the row and its children; `$M $P menu File "Reopen Closed Page"` restores them and `trails.json` equals its pre-close content.
- **Collapse.** `$M $P press-id mako.trail.1.toggle`. Rows beneath page 1 leave `menu-items Trails`.
- **Proof.** `trails.json` before and after each step, `menu-items Trails`, and a `shot` of the sidebar.

## Gotchas

- Row ids are permanent page ids, not positions; read them from `trails.json` or `tree`.
- Only the bullets marked proven have been run. The AX-driven bullets were written when the session's terminal lacked Accessibility permission; run them once before relying on them and fix this file.
- `smoke`, `perf` and `ab` still assert the old tab titles (`– 1/3`, `New Tab`) and shortcuts (⌘1). They fail until rewritten for trails.
- A page inside a collapsed row has no sidebar row; selecting it (Trails menu cannot, `trails.json` + `select` via a link can) expands the way to it.
