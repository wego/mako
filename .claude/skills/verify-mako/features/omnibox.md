# Omnibox

The address bar is a glass panel over the page. ⌘L (File → Open Location…) opens it on the current page's address to load something in this page; ⌘T opens it empty to start a trail, ⌥⌘T to open a page beneath this one, and ⌘F to find in the page. It takes a URL, a bare domain, or a search query. The status line under the field shows any error, what Enter will do, and how many trails and pages are open.

## Sub-features

- `omni-open` ⌘L opens prefilled with the shown page's address (http, https, data or file), text selected; empty when no page is shown or it shows a notice.
- `omni-purpose` the status line names what Enter does: `Loads in this page` (⌘L), `Starts a new trail` (⌘T, or ⌘L with no page open), `Opens a page beneath this one` (⌥⌘T), `Finds in this page – Enter for the next match` (⌘F).
- `omni-url` input containing `://`, or starting `about:` or `data:`, loads as typed. A bare domain (a letters-only top-level domain of two or more), `localhost` or an IPv4 address, with an optional port and path, gets `https://`, or `http://` when it starts with `localhost` or `127.`.
- `omni-search` anything else goes to the config's `search =` engine (default Google).
- `omni-status` the line under the field: first an error if there is one (the cap refusal, `Not found` from find, or a config error), then the purpose, then `N trail(s), M page(s)` counting every page, collapsed ones included (`mako.omnibox.status`).
- `omni-cap` at the trail cap, Enter for ⌘T beeps and leaves the panel open with `Can’t open: trail cap reached (N). ⌥⌘T opens a page in the current trail.`
- `omni-one-line` the field never wraps: a long address shrinks the font from 18 pt toward 11 pt to fit (18 × room ÷ width at 18 pt), past that it scrolls sideways; the panel keeps its height while typing. `scripts/ux-headed` shoots it with a long address.
- `omni-dismiss` Esc closes it without navigating; Enter on empty input does the same.
- `omni-auto` it opens on its own, for a new trail, at launch when nothing was restored and no address was passed, and after the last page closes.
- `omni-find` ⌘F reuses the panel to find in the page (`features/trails.md`, `find`).

## How to get to it (user POV)

- Press ⌘L, or choose File → Open Location….
- ⌘T / File → New Trail, ⌥⌘T / File → New Page in Trail.
- ⌘F / Edit → Find….
- It opens on its own when no page is open.

## Driving it with makoctl

Preconditions: baseline, launched with `$C launch "" https://example.com`; `MAKO_BACKGROUND=1` is fine except for the steps marked (focus).

- **Open.** `$M $P menu File "Open Location…"`. `$M $P value mako.omnibox.field` prints `https://example.com/`; `$M $P value mako.omnibox.status` prints `Loads in this page` and `1 trail, 1 page`. **(focus)** `key cmd+l` does the same.
- **Purposes.** `menu File "New Trail"`, `menu File "New Page in Trail"` and `menu Edit "Find…"` each put their purpose (above) in `mako.omnibox.status`.
- **Bare domain.** `menu File "Open Location…"; set mako.omnibox.field iana.org; confirm mako.omnibox.field`. `wait-title "Internet Assigned" 8` succeeds and `trails.json` still holds one page.
- **Local address.** With `fixture-server $PORT` running, the same with `127.0.0.1:$PORT/c.html`: `wait-title "Page C"`, and the page's `url` in `trails.json` starts `http://`.
- **Search.** The same with `rust lifetimes`: `wait-title "rust lifetimes" 8` (Google's results title).
- **Cap.** `menu File "New Trail"`, `set` an address, `confirm`, twice: three trails. A fourth: `value mako.omnibox.status | head -1` is `Can’t open: trail cap reached (3). ⌥⌘T opens a page in the current trail.` and `trails.json` still has three roots.
- **Dismiss.** `menu File "Open Location…"; set mako.omnibox.field ""; confirm mako.omnibox.field`: the panel closes and the title is unchanged. **(focus)** `key cmd+l; type zzz; key escape`: title unchanged.
- **On its own.** `$C stop; $C launch` (no address): `title` is `Mako`, `exists mako.blank` exits 0, and the status is `Starts a new trail` / `0 trails, 0 pages`.
- **Proof.** `$M $P tree 6 > $E/omni-tree.txt; $M $P shot $E/omni.png` with the panel open.

## Gotchas

- `mako.omnibox*` elements stay in the AX tree while the panel is hidden, so `exists` does not prove visibility. Use `shot` for that.
- `v1.2`-style input is treated as search, not a domain, by design (the top-level domain must be letters).
- `set` changes the field without the typing notification, and the font is refit on typing (from source), so judge `omni-one-line` from typed input, as `ux-headed` does.
- The status line keeps its last text while the panel is hidden; read it after opening the panel.
