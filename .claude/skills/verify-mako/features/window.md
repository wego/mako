# Window

Mako's window has no title bar of its own. The page and the sidebar run to the window's top edge, the traffic lights sit on the sidebar's paper above the first card, and the page title still names the window in the Window list, Mission Control and accessibility. The sidebar's paper is the grip: dragging it moves the window, and a double-click on it does what a title-bar double-click does. View → Hide Sidebar (⌃⌘S), or the sidebar icon in the sidebar's bottom-right corner, leaves only the page: the traffic lights hide too, an 8 pt strip along the top edge becomes the grip, and the pointer reaching the window's left edge slides the sidebar in over the page until the pointer leaves it. The choice is kept across restarts.

## Sub-features

- `window-chromeless` the page (`mako.page`) and the sidebar (`mako.sidebar`) start at the window's top edge; the first card starts below the traffic lights.
- `window-title` the window keeps its title (the active page's name) for the Window list, Mission Control and `makoctl title`, though none is drawn.
- `window-move` dragging the sidebar's paper (the band above the cards, the margins and gaps between and below them) moves the window; rows, toggles, the corner button, the scroller and the notes keep their own clicks, and a drag that starts on the divider only resizes the sidebar, even once the pointer crosses onto the paper or past the narrowest width. With the sidebar hidden, dragging the top 8 pt strip moves the window.
- `window-double-click` a double-click on the sidebar's paper or the top strip zooms, minimizes or does nothing, following System Settings → Desktop & Dock → "Double-click a window's title bar to" (`AppleActionOnDoubleClick`).
- `window-page-top` the page's top takes clicks where a title bar used to be; with the sidebar hidden, the top strip takes the first 8 pt instead.
- `sidebar-hide` View → Hide Sidebar / Show Sidebar (⌃⌘S, which pages cannot take) hides the sidebar, its divider and the traffic lights, or brings them back. The menu item's title says which. Hidden, the sidebar and divider leave the AX tree; the Trails menu and ⌘1…⌘9 still navigate. Trails → Rename Page… brings a hidden sidebar back, since the name is edited in its row. Kept across restarts (`sidebarHidden` in the app's defaults).
- `sidebar-button` a sidebar icon (`sidebar.left`) at the sidebar's bottom-right corner (`mako.sidebar.toggle`, AX label and tooltip "Hide Sidebar") hides the sidebar like ⌃⌘S. On a peeking sidebar it reads "Keep Sidebar Open" and pins the sidebar beside the page. The cards and the footer notes stop short of it.
- `sidebar-peek` with the sidebar hidden, the pointer at the window's left edge (6 pt) slides the sidebar in over the page with a shadow, traffic lights included; the page does not move. Clicks at that edge still reach the page. The pointer leaving the sidebar slides it away, unless a rename is in progress.

## How to get to it (user POV)

- Drag or double-click the sidebar's empty paper; drag the top edge with the sidebar hidden.
- View → Hide Sidebar / Show Sidebar, ⌃⌘S, or the sidebar icon at the sidebar's bottom-right.
- Move the pointer to the window's left edge with the sidebar hidden.

## Driving it with makoctl

- **AX, no focus.** `.claude/skills/verify-mako/scripts/chrome-ax` covers `window-chromeless`, `window-title` and `sidebar-hide` (menu, AX tree, page frame, traffic lights, restart, the corner button, Rename Page… while hidden, and that the page is painted in each state). 26 checks.
- **Headed.** `.claude/skills/verify-mako/scripts/chrome-headed` covers `window-move`, `window-double-click`, `window-page-top`, `sidebar-peek`, `sidebar-button` on a peek, a divider drag past the narrowest width that must not move the window, and `sidebar-hide` as the real ⌃⌘S key, with `drag`, `double-click`, `hover` and `click-id` against `fixtures/chrome/top.html` (a button over the page's top 28 px). Takes focus and moves the pointer: warn the person first. Needs synthetic pointer events to reach Mako: over a remote session such as Jump Desktop keys arrive but clicks do not, so it first runs `scripts/pointer-check` (a big centred button whose click sets the title), and when that click does not land it prints `UNREACHABLE pointer events don't reach Mako …` and exits 98 without running the rest. If `key-hides-sidebar` fails, it stops there instead of running the hidden-sidebar checks against a shown sidebar.
- **Frames.** `$M $P window-frame` and `$M $P frame mako.page` / `mako.sidebar` / `mako.trail.<id>` are screen points from the top-left; equal `y` for the window and the page proves the page reaches the top edge.
- **Proof.** `shot` with the sidebar shown, hidden and peeking.

## Gotchas

- The traffic lights are AX `AXCloseButton` / `AXMinimizeButton` / `AXZoomButton` children of the window; hidden with the sidebar, they leave the tree.
- `double-click` follows the person's own `AppleActionOnDoubleClick`; `chrome-headed` reads it first and expects the matching result.
- A peek needs the pointer to enter the edge; a pointer already resting there when the sidebar hides does not peek until it leaves and returns.
