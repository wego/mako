# Trails

Trails replace tabs. A trail is a tree of pages in the sidebar: a followed link opens as a new page beneath the page it came from. Up to `max_trails` (default 3, set in Settings, ⌘.) trails exist at once; pages within a trail are unlimited. Trails, and the stack of closed pages, are saved after every change and come back at launch.

## Sub-features

- `trail-link` a clicked link (including `target=_blank`) opens a child page and selects it.
- `trail-in-place` a `#fragment` jump, form submit, redirect, or ⌘L address changes the current page; no new page.
- `trail-new` ⌘T starts a trail from the omnibox; at the cap Enter beeps and `mako.omnibox.status` starts `Can’t open: trail cap reached (N). ⌥⌘T opens a page in the current trail.`
- `trail-load` at the cap the sidebar's foot shows a quiet `🧠 3/3` (`mako.sidebar.load`, tooltip "At your trail limit – finish or close a trail to start another"); below the cap it is gone from the window and the AX tree.
- `trail-child` ⌥⌘T opens a page beneath the current one from the omnibox (with no page open it starts a trail).
- `trail-external` a link from another app starts a trail, or at the cap opens beneath the current page.
- `trail-select` a sidebar row, a Trails menu item, or ⌃Tab / ⌃⇧Tab (Trails → Next Page / Previous Page, wrapping around the visible rows) selects a page.
- `trail-jump` ⌘1…⌘9 (the trail's root item in the Trails menu) selects that trail's root; pressed on the root, its last page (last child, repeatedly); pressed there, the root again. A one-page trail stays on its root. A page inside a collapsed row is reached too, and the way to it expands. ⌘N with no Nth trail has no menu item, so Mako does nothing and the key goes on to the page.
- `trail-close` ⌘W closes the active page and everything beneath it; the next sibling becomes active, else the previous one, else the parent. Closing the last page opens the omnibox for a new trail. With the About panel, Settings or a sign-in popup in front, ⌘W closes that window instead.
- `trail-undo` ⇧⌘T reopens the last closed page with its subtree where it was, also after a restart; up to 20 closes are kept. A page whose parent is gone comes back as a trail of its own, and beeps instead at the cap.
- `trail-collapse` a row's toggle (▾ / ▸ at its trailing edge) hides or shows the pages beneath it.
- `trail-restore` quitting and reopening shows the same tree and active page; only the active page loads.
- `trail-move` Trails → Move Page Up / Down, Indent Page, Outdent Page move the active page and everything beneath it; dragging a row onto another drops it before, after or inside that page. A move that would start a trail beyond the cap is refused with a beep.
- `trail-rename` double-click a row, right-click → Rename…, or Trails → Rename Page…; Enter saves, Escape cancels, an empty name goes back to the page title.
- `trail-background-link` ⌘-click opens the link beneath the page without leaving it.
- `trail-middle-click` middle-click on a link (`target=_blank` and single-page-app links included) opens it beneath the page in the background. On a download link (`<a download>`) or anything else it is a real left click, so a download link still downloads: a navigation it starts within a second (`location = …`, `window.open`) opens in the background instead, and a control that does not navigate just runs its handler. Middle-click on a sidebar row closes that page (⇧⌘T undoes).
- `trail-colors` each open trail has its own colour (`colors` in `trails.json`, keyed by root id): its card (one raised card per trail on the cream sidebar) and the active row are tinted with it, the root row carries a dot and each page beneath an L-shaped ink branch in it, and its Trails menu item a dot. A trail keeps its colour while others close or move; a new trail takes the lowest free one.
- `favicons` each row shows its page's icon: the one the loaded page declares (`link[rel~=icon]`, else `apple-touch-icon`), else its site's `/favicon.ico`, so rows of pages not loaded yet get one too. Two pages on one site that declare different icons each show their own, and a `/favicon.ico` that arrives late never replaces a declared icon. A faint globe holds the place until then. Icons are fetched without cookies, only for http(s), never for a blocked host (redirects included), at most 1 MB, and only PNG, ICO, GIF or JPEG are decoded; an icon address that fails is not asked again until restart. The log says `favicon <host>[:<port>] from <url>` or `favicon <host>[:<port>] none at <url>`.
- `sidebar-scroller` the sidebar shows a scroller only when its rows overflow, even with "Show scroll bars: Always".
- `sidebar-width` the sidebar starts at a fifth of the window (200–320 pt), drags by its edge between 160 pt and the smaller of 480 pt and the window width less 400, and keeps its width across restarts.
- `trail-indent-cap` each level beneath the first indents a row 16 pt, up to the deepest level that leaves its name 40 pt beside the toggle; deeper pages sit at that level. At the narrowest sidebar two levels still show.
- `find` ⌘F finds in the page from the omnibox; Enter or ⌘G next, ⇧⌘G previous.
- `download` a file WebKit cannot show, or an `<a download>` link, is saved to `~/Downloads` (a run's `MAKO_DOWNLOADS`), renamed `name 2.ext` rather than overwriting, and quarantined so Gatekeeper checks it. Only the page itself may start one, never an embedded frame or a blocked host.
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
- **AX, no focus.** `.claude/skills/verify-mako/scripts/trails-ax` covers `trail-select`, `trail-collapse`, `trail-new` and the cap, `trail-child`, `trail-close`, `trail-undo` (also after a restart) through `press-id`, `menu`, `set` and `confirm`, plus `trail-move` (menu moves), `trail-rename`, `sidebar-width`, `trail-indent-cap`, `find`, `trail-jump` (menu items) and `trail-load`. It lowers the cap to 2 in Settings first, so its cap messages say `(2)`. 59 checks. The bullets below are what it runs, at the default cap.
- **Headed.** `.claude/skills/verify-mako/scripts/ux-headed` covers `trail-middle-click` (a link, a `target=_blank` link, a script navigation, a button, a single-page-app link, `window.open`, a download link, a sidebar row), `trail-jump` as a real ⌘1 key, `omni-one-line` and `favicons` by colour. 24 checks.
- **Link.** Launch on `$U/a.html`. `$M $P menu-items Trails` lists `Page A`, `Page B`, `Page C` with `Page C` checked; `python3 -m json.tool verify-runs/latest/state/trails.json` shows page 3 under 2 under 1.
- **New trail and cap.** `$M $P menu File "New Trail"; $M $P set mako.omnibox.field "$U/c.html?t2"; $M $P confirm mako.omnibox.field`. A second root appears in `trails.json`. Repeat with `?t3`: a third root, and `value mako.sidebar.load` is `🧠 3/3`. A fourth: `value mako.omnibox.status` starts `Can’t open: trail cap reached (3)` and `roots` stays at three. **(focus)** `key cmd+t` opens the same omnibox.
- **Select.** `$M $P press-id mako.trail.1`. `title` is `Page A`; `value mako.trail.1` is `selected`.
- **Close and undo.** `$M $P menu File "Close Page"` removes the row and its children; `$M $P menu File "Reopen Closed Page"` restores them and `trails.json` equals its pre-close content.
- **Collapse.** `$M $P press-id mako.trail.1.toggle`. Rows beneath page 1 leave `menu-items Trails`.
- **Move and rename.** With page 6 active under page 4 beside page 5: `menu Trails "Indent Page"` puts 6 under 5, `"Outdent Page"` back after 5. `menu Trails "Rename Page…"; set mako.trail.6.name Mine; confirm mako.trail.6.name`; `title` is `Mine`.
- **Width.** `value mako.divider` is `240` in a fresh 1200 pt window; `set mako.divider 9999` reads `480`, `set mako.divider 100` reads `160`; `set mako.divider 300` then `$C quit; $C relaunch` still reads `300`.
- **Keys (focus).** `key ctrl+tab` and `key ctrl+shift+tab` step the active page (`trails.json` `active`); `key cmd+w` closes it and `key cmd+shift+t` reopens it; `key cmd+opt+t` opens the omnibox with `Opens a page beneath this one` in `mako.omnibox.status`; on `c.html`, `key cmd+f`, `type leaf`, `key return`, then `key cmd+g` and `key cmd+shift+g` find with no `Not found` in the status, while `type zzzqqq` and `key return` shows it.
- **Proof.** `trails.json` before and after each step, `menu-items Trails`, and a `shot` of the sidebar.

## Gotchas

- Row ids are permanent page ids, not positions; read them from `trails.json` or `tree`.
- Reopening a closed page reloads it. A fixture page that clicks its own link (a.html, b.html) then opens a new child again, so assert Undo Close with pages that do not (c.html).
- ⌘T, ⌥⌘T, ⌘W, ⇧⌘T, ⌃Tab, ⌘F and ⌘G as real key presses are covered by no script; they share the menu actions the scripts press, and the **Keys** bullet above drives them by hand.
- `ux-headed` judges icons by colour: `g.html` and `h.html` declare magenta and cyan icons; a yellow `/favicon.ico` must not show.
- Not covered by any script: a real drag and drop, ⌘-click, the pointing-hand cursor and hover highlight (need a pointer, so a headed run), and downloads other than the middle-clicked download link.
- A page inside a collapsed row has no sidebar row and no Trails menu item. ⌘1…⌘9 from the trail's root can still reach it (the jump goes to the last page down the last children) and expands the way to it.
- At the cap, `$C launch` and `relaunch` URLs open beneath the active page instead of as trails.
