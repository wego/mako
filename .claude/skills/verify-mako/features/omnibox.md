# Omnibox

The address bar is a glass panel summoned with ⌘L. It accepts a URL, a bare domain, or a search query, and lists open tabs underneath.

## Sub-features

- `omni-open` opens prefilled with the current page URL, text selected.
- `omni-url` loads a bare domain as https.
- `omni-search` sends free text to the configured search engine.
- `omni-dismiss` Esc closes it without navigating.

## How to get to it (user POV)

- Press ⌘L.
- Choose File → Open Location….
- ⌘T opens it empty on a new tab (see Tabs).

## Driving it with makoctl

Preconditions: baseline, launched with `$C launch "" https://example.com`.

- **Open.** `$M $P key cmd+l`. `$M $P value mako.omnibox.field` prints the current URL.
- **Open via menu.** `$M $P key escape; $M $P menu File "Open Location…"`. `exists mako.omnibox.field` exits 0.
- **Bare domain.** `$M $P type example.com; $M $P key return`. `$M $P wait-title "Example Domain"` succeeds.
- **Search.** `$M $P key cmd+l; $M $P type "rust lifetimes"; $M $P key return`. `wait-title "rust lifetimes"` succeeds (Google results title).
- **Dismiss.** `$M $P key cmd+l; $M $P type zzz; $M $P key escape`. Title unchanged.
- **Proof.** `$M $P tree 6 > $E/omni-tree.txt; $M $P shot $E/omni.png` with the panel open.

## Gotchas

- `mako.omnibox*` elements stay in the AX tree while the panel is hidden, so `exists` does not prove visibility. Use `shot` for that.
- `v1.2`-style input is treated as search, not a domain, by design (TLD must be letters).
