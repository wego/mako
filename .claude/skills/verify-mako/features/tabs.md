# Tabs

Mako has no tab bar. Tabs are capped (`max_tabs`, default 3), switched with ⌘1–9 or the Tabs menu, and named in the window title as `<page title> – <i>/<n>`. A blank tab shows the app icon.

## Sub-features

- `tab-new` ⌘T opens a blank tab with the omnibox.
- `tab-cap` ⌘T at the cap beeps and shows "Tab cap reached (3)…" without adding a tab.
- `tab-switch` ⌘<n> and Tabs menu items switch tabs; the menu checks the active tab.
- `tab-close` ⌘W closes; closing the last tab leaves one fresh blank tab.
- `tab-title` window title tracks the active tab's title, falling back to host, then `New Tab`.
- `tab-blank-icon` a blank tab shows `mako.blank` (the app icon) instead of an empty page.

## How to get to it (user POV)

- ⌘T / File → New Tab.
- ⌘1–9 / Tabs → <tab name>.
- ⌘W / File → Close Tab.

## Driving it with makoctl

Preconditions: baseline launched with `https://example.com`.

- **Title.** `$M $P wait-title "Example Domain – 1/1"`.
- **New tab.** `$M $P key cmd+t`. Title ends `– 2/2`; `exists mako.blank` exits 0; `shot $E/tab-blank.png` shows the icon.
- **Fill to cap.** `$M $P key escape; $M $P menu File "New Tab"; $M $P key escape`. Title is `New Tab – 3/3`.
- **Cap.** `$M $P key cmd+t`. Title still `– 3/3`; `value mako.omnibox.status` starts with `Tab cap reached (3)`.
- **Switch.** `$M $P key escape; $M $P key cmd+1`. `wait-title "Example Domain – 1/3"`. `$M $P menu-items Tabs` prints `* Example Domain` plus two `New Tab` lines.
- **Switch via menu.** `$M $P menu Tabs "New Tab"`. Title is `New Tab – 2/3`; `menu-items Tabs` now checks the second item.
- **Close to last.** `$M $P key cmd+w` three times. Title is `New Tab – 1/1` and `exists mako.blank` exits 0.

## Gotchas

- Tab names repeat (`New Tab`), so `menu Tabs "New Tab"` presses the first match.
- The cap message lives in `mako.omnibox.status`, not an alert.
- Proven runs: `verify-runs/<run>/evidence/tabs.txt` lists PASS lines for title, blank tab, cap, ⌘1, menu switch, and close-to-last.
