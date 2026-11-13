# Trails

Trails replace tabs. A trail is a tree of pages in the sidebar: a followed link opens as a new page beneath the page it came from. Up to `max_trails` (default 3, set in Settings, ⌘.) trails exist at once; pages within a trail are unlimited. Trails, and the stack of closed pages, are saved after every change and come back at launch.

## Sub-features

- `trail-link` a clicked link (including `target=_blank`) opens a child page and selects it.
- `trail-in-place` a `#fragment` jump, form submit, redirect, or ⌘L address changes the current page; no new page.
- `trail-new` ⌘T starts a trail; refused at the cap with a message in `mako.omnibox.status`.
- `trail-load` at the cap the sidebar's foot shows a quiet `🧠 3/3` (`mako.sidebar.load`, tooltip "At your trail limit – finish or close a trail to start another"); below the cap it is gone from the window and the AX tree.
- `trail-child` ⌥⌘T opens a page beneath the current one from the omnibox.
- `trail-external` a link from another app starts a trail, or at the cap opens beneath the current page.
- `trail-select` a sidebar row, a Trails menu item, or ⌃Tab / ⌃⇧Tab selects a page.
- `trail-jump` ⌘1…⌘9 (the trail's root item in the Trails menu) selects that trail's root; pressed on the root, its last page (last child, repeatedly); pressed there, the root again. A one-page trail stays on its root; a missing trail beeps.
- `trail-close` ⌘W closes the active page and everything beneath it; a neighbour becomes active.
- `trail-undo` ⇧⌘T reopens the last closed page with its subtree where it was, also after a restart.
- `trail-collapse` a row's toggle hides or shows the pages beneath it.
- `trail-restore` quitting and reopening shows the same tree and active page; only the active page loads.
- `trail-move` Trails → Move Page Up / Down, Indent Page, Outdent Page move the active page and everything beneath it; dragging a row onto another drops it before, after or inside that page. A move that would make a third trail is refused.
- `trail-rename` double-click a row, right-click → Rename…, or Trails → Rename Page…; Enter saves, Escape cancels, an empty name goes back to the page title.
- `trail-background-link` ⌘-click opens the link beneath the page without leaving it.
- `trail-middle-click` middle-click on a link (`target=_blank` and single-page-app links included) opens it beneath the page in the background. On a download link (`<a download>`) or anything else it is a real left click, so a download link still downloads: a navigation it starts within a second (`location = …`, `window.open`) opens in the background instead, and a control that does not navigate just runs its handler. Middle-click on a sidebar row closes that page (⇧⌘T undoes).
- `trail-colors` each open trail has its own colour (`colors` in `trails.json`, keyed by root id): a rail down the rows' leading edge, the active row tinted with it, a dot on its Trails menu item. A trail keeps its colour while others close or move; a new trail takes the lowest free one.
- `favicons` each row shows its page's icon: the one the loaded page declares (`link[rel~=icon]`, else `apple-touch-icon`), else its site's `/favicon.ico`, so rows of pages not loaded yet get one too. Two pages on one site that declare different icons each show their own, and a `/favicon.ico` that arrives late never replaces a declared icon. A faint globe holds the place until then. Icons are fetched without cookies, only for http(s), never for a blocked host (redirects included), at most 1 MB, and only PNG, ICO, GIF or JPEG are decoded; an icon address that fails is not asked again until restart. The log says `favicon <host> from <url>` or `none at <url>`.
- `sidebar-scroller` the sidebar shows a scroller only when its rows overflow, even with "Show scroll bars: Always".
- `sidebar-width` the sidebar starts at a fifth of the window (200–320 pt), drags by its edge, and keeps its width across restarts.
- `find` ⌘F finds in the page from the omnibox; Enter or ⌘G next, ⇧⌘G previous.
- `download` a file WebKit cannot show is saved to `~/Downloads`.
- `trail-blocked-link` a link to a blocked host opens a child page showing the block notice.

## How to get to it (user POV)

- Click a link on a page.
- File → New Trail (⌘T), New Page in Trail (⌥⌘T), Close Page (⌘W), Reopen Closed Page (⇧⌘T).
- Click a row or its toggle in the sidebar; Trails menu; ⌃Tab.
- Drag a row; double-click or right-click a row; drag the sidebar edge.
- Open a link from another app.

## Driving it with makoctl

Preconditions: baseline. For background runs set `MAKO_BACKGROUND=1` (then use `menu`, `press-id`, `set`, `confirm`; no `key`/`type`). Fixture pages that click their own links are in `fixtures/trails/`; serve them with `.claude/skills/verify-mako/scripts/fixture-server $PORT &` (its `/favicon.ico` answers after 3 s).

- **No permissions, no focus.** `.claude/skills/verify-mako/scripts/trails-bg` covers `trail-link`, `trail-in-place`, `trail-external`, `trail-restore`, `trail-blocked-link`, `trail-colors` and `favicons` by reading `trails.json` and the log. 24 checks.
- **AX, no focus.** `.claude/skills/verify-mako/scripts/trails-ax` covers `trail-select`, `trail-collapse`, `trail-new` and the cap, `trail-child`, `trail-close`, `trail-undo` (also after a restart) through `press-id`, `menu`, `set` and `confirm`, plus `trail-move` (menu moves), `trail-rename`, `sidebar-width`, `find`, `trail-jump` (menu items) and `trail-load`. 48 checks. The bullets below are what it runs.
- **Link.** Launch on `$U/a.html`. `$M $P menu-items Trails` lists `Page A`, `Page B`, `Page C` with `Page C` checked; `python3 -m json.tool verify-runs/latest/state/trails.json` shows page 3 under 2 under 1.
- **New trail and cap.** `$M $P menu File "New Trail"; $M $P set mako.omnibox.field example.com; $M $P confirm mako.omnibox.field`. A second root appears. Repeat: `value mako.omnibox.status` starts `Can’t open: trail cap reached (2)`.
- **Select.** `$M $P press-id mako.trail.1`. `title` is `Page A`; `value mako.trail.1` is `selected`.
- **Close and undo.** `$M $P menu File "Close Page"` removes the row and its children; `$M $P menu File "Reopen Closed Page"` restores them and `trails.json` equals its pre-close content.
- **Collapse.** `$M $P press-id mako.trail.1.toggle`. Rows beneath page 1 leave `menu-items Trails`.
- **Move and rename.** With page 6 active under page 4 beside page 5: `menu Trails "Indent Page"` puts 6 under 5, `"Outdent Page"` back after 5. `menu Trails "Rename Page…"; set mako.trail.6.name Mine; confirm mako.trail.6.name`; `title` is `Mine`.
- **Width.** `value mako.divider` is `240` in a fresh 1200 pt window; `set mako.divider 300` then a relaunch still reads `300`.
- **Proof.** `trails.json` before and after each step, `menu-items Trails`, and a `shot` of the sidebar.

## Gotchas

- Row ids are permanent page ids, not positions; read them from `trails.json` or `tree`.
- Reopening a closed page reloads it. A fixture page that clicks its own link (a.html, b.html) then opens a new child again, so assert Undo Close with pages that do not (c.html).
- ⌘T, ⌥⌘T, ⌘W, ⇧⌘T and ⌃Tab as real key presses are not covered by either script (keys need focus); they share the menu actions the scripts press.
- `scripts/ux-headed` (takes the pointer and keyboard) covers middle-click on `fixtures/trails/m.html` (a download link included, saved to the run's `MAKO_DOWNLOADS`) and on sidebar rows, ⌘1 as a key, and which icon each row shows (`g.html` and `h.html` declare magenta and cyan icons; a yellow `/favicon.ico` must not show).
- Not covered by any script: a real drag and drop, ⌘-click, the pointing-hand cursor and hover highlight (need a pointer, so a headed run), and downloads other than the middle-clicked download link.
- `smoke`, `perf` and `ab` still assert the old tab titles (`– 1/3`, `New Tab`) and shortcuts (⌘1). They fail until rewritten for trails.
- A page inside a collapsed row has no sidebar row; selecting it (Trails menu cannot, `trails.json` + `select` via a link can) expands the way to it.
