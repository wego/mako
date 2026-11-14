# Accessibility tree

Agents and assistive tech read and drive Mako through the macOS AX tree: the shown page's web content, Mako's own controls by stable identifier, and every visible page through the Trails menu. Everything a person does with the sidebar, the omnibox, Settings and page dialogs has an AX action (press, set a value, confirm), so none of it needs a pointer or a key press.

## Sub-features

- `ax-web` the shown page's content appears as one `AXWebArea` with its text and links; `makoctl text` reads its text untruncated.
- `ax-ids` Mako's controls carry the identifiers in `docs/control.md` (AX handles): `mako.sidebar`; a row per visible page, `mako.trail.<id>` (role button, title the page's label, value `selected` on the active page); `mako.trail.<id>.toggle` (only on rows with pages beneath, labelled Collapse or Expand); `mako.trail.<id>.close` (every row, labelled Close page, or Close page and pages beneath; in the tree even while not painted); `mako.trail.<id>.name` (only while renaming); `mako.trail.<id>.page` (the shown page's web view); `mako.sidebar.load` (only at the trail cap); `mako.divider` (role splitter, value the sidebar width); `mako.page`; `mako.omnibox`, `mako.omnibox.field` (its label names what Enter does), `mako.omnibox.status` (only with a message), `mako.omnibox.scrim` (button, Close address bar); `mako.blank` (only with no page open); `mako.popup`; `mako.dialog.ok`, `.cancel`, `.field`, `.silence`; `mako.settings.maxTrails` and `.stepper`.
- `ax-actions` pressing a row selects its page, pressing a toggle collapses or expands, pressing a close control closes that page, pressing the scrim closes the omnibox, `set` resizes the divider and fills the omnibox, rename, Settings and prompt fields, and `confirm` is Enter in a field.
- `ax-trails-menu` the Trails menu lists every visible page, indented by depth, the active one checked, each trail's root carrying ⌘1…⌘9. It is rebuilt on every change, so it is current without being opened.
- `ax-no-systabs` no `AXTabGroup`: macOS window tabbing is off.

## How to get to it (user POV)

- Any AX client: VoiceOver, Accessibility Inspector, or `makoctl tree`.

## Driving it with makoctl

Preconditions: baseline; `MAKO_BACKGROUND=1` is fine for every step. Serve the trail fixtures (`.claude/skills/verify-mako/scripts/fixture-server $PORT &`, `U=http://127.0.0.1:$PORT`) and launch with `$C launch "" "$U/a.html"`; after ~2 s it holds Page A, Page B beneath it and Page C beneath that, Page C active.

- **Web content.** `$M $P tree 12 > $E/ax-page.txt` contains an `AXWebArea`; `$M $P text` prints `leaf`.
- **Identifiers.** `$M $P tree 20 | grep -o 'id="mako[^"]*"' | sort -u > $E/ax-ids.txt`. Expected from source: `mako.divider`, `mako.page`, `mako.sidebar`, `mako.sidebar.toggle`, `mako.trail.1`, `mako.trail.1.close`, `mako.trail.1.toggle`, `mako.trail.2`, `mako.trail.2.close`, `mako.trail.2.toggle`, `mako.trail.3`, `mako.trail.3.close`, `mako.trail.3.page`; no `mako.omnibox*` (closed), no `mako.sidebar.load` (one trail of three) and no `mako.blank`.
- **Row state.** `value mako.trail.3` is `selected`; `value mako.trail.1` is empty.
- **Actions.** `press-id mako.trail.1`: `title` is `Page A`. `press-id mako.trail.1.toggle`: `exists mako.trail.2` exits 4 and `menu-items Trails` no longer lists Page B; press it again and both return. `set mako.divider 300`: `value mako.divider` is `300`. `press-id mako.trail.3.close`: `exists mako.trail.3` exits 4; `menu File "Reopen Closed Page"` brings it back.
- **Trails menu.** `$M $P menu-items Trails` lists Next Page, Previous Page, Move Page Up, Move Page Down, Indent Page, Outdent Page, Rename Page…, then the pages, the active one starred. `$M $P tree 20 --menus | grep 'title="Page A"'` shows `cmd="1"`.
- **Handles that come and go.** `menu Mako "Settings…"`: `exists mako.settings.maxTrails` exits 0 and `windows` lists a `Settings` window. With Page A active, `menu File "Close Page"` closes the whole trail: `exists mako.blank` exits 0 and `title` is `Mako`. Dialog handles: `features/dialogs.md`; `mako.sidebar.load`: `features/trails.md`.
- **No system tab group.** `$M $P tree 4 | grep -c AXTabGroup` prints 0.

## Gotchas

- `tree` without `--menus` omits the menu bar; read menu state with `menu-items`.
- Only the shown page's web view is in the window, so other loaded pages' `mako.trail.<id>.page` are absent from the tree.
- The × and an expanded row's toggle are in the tree with a frame while not painted (alpha 0); prove what shows with a `shot`.
- `mako.omnibox*` leave the tree while the panel is hidden (`exists` exits 4), so `exists mako.omnibox` proves the panel is showing.
- `makoctl` does not print AX help, so a row's `site icon` / `no site icon` help is not readable through it; `ux-headed` judges icons by colour.
- A plain NSView only shows up in the AX tree when marked as an accessibility element with a role. New Mako containers need both, or their identifier silently disappears.
- Two pages with one title give two Trails menu items with that title; `menu Trails "<title>"` presses the first. Use `press-id mako.trail.<id>` to pick one.
