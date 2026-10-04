# Accessibility tree

Agents and assistive tech read Mako through the macOS AX tree: the page's web content, Mako's own controls by stable identifier, and tabs through the Tabs menu.

## Sub-features

- `ax-web` page content appears as `AXWebArea` with text and links.
- `ax-ids` Mako controls carry identifiers `mako.page`, `mako.omnibox`, `mako.omnibox.field`, `mako.omnibox.status`, `mako.blank`, `mako.tab.<n>`.
- `ax-tabs` the Tabs menu lists open tabs by name with the active one checked.
- `ax-no-systabs` no `AXTabGroup` (macOS automatic window tabbing is disabled).

## How to get to it (user POV)

- Any AX client: VoiceOver, Accessibility Inspector, or `makoctl tree`.

## Driving it with makoctl

Preconditions: baseline launched with `https://example.com`.

- **Web content.** `$M $P tree 8 > $E/ax-page.txt`. Contains `AXWebArea desc="Example Domain"` and `AXLink title="Learn more"`.
- **Identifiers.** `$M $P key cmd+l; $M $P tree 9 > $E/ax-omnibox.txt; grep -o 'id="mako[^"]*"' $E/ax-omnibox.txt | sort -u` lists `mako.omnibox`, `mako.omnibox.field`, `mako.omnibox.status`, `mako.page`, `mako.tab.1`. `mako.blank` appears only on a blank tab.
- **Tabs.** `$M $P key cmd+t; $M $P key escape; $M $P menu-items Tabs` prints `  Example Domain` and `* New Tab`. The menu is current without being opened.
- **No system tab group.** `$M $P tree 3 | grep -c AXTabGroup` prints 0.

## Gotchas

- `tree` without `--menus` omits the menu bar; read menu state with `menu-items`.
- A plain NSView only shows up in the AX tree when marked as an accessibility element with a role. New Mako containers need both, or their identifier silently disappears.
