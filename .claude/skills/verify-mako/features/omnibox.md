# Omnibox

The address bar is a glass panel over the page. ⌘L (File → Open Location…) opens it on the current page's address to load something in this page; ⌘T opens it empty to start a trail, ⌥⌘T to open a page beneath this one, and ⌘F to find in the page. It takes a URL, a bare domain, or a search query. While it is open a scrim dims the whole window, sidebar included, and an ink ring with a deep shadow lifts the panel, so an open omnibox is never missed. A status line under the field appears only for an error or a message.

## Sub-features

- `omni-open` ⌘L opens prefilled with the shown page's address (http, https, data or file), text selected; empty when no page is shown or it shows a notice.
- `omni-purpose` the field's accessibility label names what Enter does: `This page – search or enter address` (⌘L), `New trail – search or enter address` (⌘T, or ⌘L with no page open), `New page beneath this one – search or enter address` (⌥⌘T), `Find in this page` (⌘F). Nothing on screen says it; the placeholder is `Search or enter address`.
- `omni-url` input containing `://`, or starting `about:` or `data:`, loads as typed. A bare domain (a letters-only top-level domain of two or more), `localhost` or an IPv4 address, with an optional port and path, gets `https://`, or `http://` when it starts with `localhost` or `127.`.
- `omni-search` anything else goes to the config's `search =` engine (default Google).
- `omni-status` the line under the field (`mako.omnibox.status`, terracotta) shows only an error or a message: the cap refusal, `Not found` from find (cleared by the next hit), or else a config error. With none it is gone from the panel and the AX tree. Opening the omnibox again drops the last message.
- `omni-cap` at the trail cap, Enter for ⌘T beeps and leaves the panel open with `Can’t open: trail cap reached (N). ⌥⌘T opens a page in the current trail.`
- `omni-one-line` the field never wraps: a long address shrinks the font from 18 pt toward 11 pt to fit (18 × room ÷ width at 18 pt), past that it scrolls sideways; the panel keeps its height while typing. `scripts/ux-headed` shoots it with a long address.
- `omni-dismiss` Esc closes it without navigating; Enter on empty input does the same. So does a click anywhere outside the panel, on the page, the sidebar or any other part of the dimmed window: the click lands on the scrim (`mako.omnibox.scrim`, an AX button labelled Close address bar) and does nothing else, so a click meant to dismiss never follows a link or selects a row. Switching to another app leaves it open.
- `omni-scrim` the scrim is warm brown at 32% in light mode and black at 55% in dark mode; the ring is the sidebar's ink (dark brown in light mode, cream in dark), 2 pt, 3 pt outside the glass.
- `omni-auto` it opens on its own, for a new trail, at launch when nothing was restored and no address was passed, and after the last page closes.
- `omni-find` ⌘F reuses the panel to find in the page (`features/trails.md`, `find`).

## How to get to it (user POV)

- Press ⌘L, or choose File → Open Location….
- ⌘T / File → New Trail, ⌥⌘T / File → New Page in Trail.
- ⌘F / Edit → Find….
- It opens on its own when no page is open.

## Driving it with makoctl

Preconditions: baseline, launched with `$C launch "" https://example.com`; `MAKO_BACKGROUND=1` is fine except for the steps marked (focus).

- **Open.** `$M $P menu File "Open Location…"`. `$M $P value mako.omnibox.field` prints `https://example.com/`; `$M $P tree | grep mako.omnibox.field` shows `desc="This page – search or enter address"` and `exists mako.omnibox.status` exits 4. **(focus)** `key cmd+l` does the same.
- **Purposes.** `menu File "New Trail"`, `menu File "New Page in Trail"` and `menu Edit "Find…"` each put their purpose (above) in `mako.omnibox.field`'s `desc`, and none shows `mako.omnibox.status`.
- **Bare domain.** `menu File "Open Location…"; set mako.omnibox.field iana.org; confirm mako.omnibox.field`. `wait-title "Internet Assigned" 8` succeeds and `trails.json` still holds one page.
- **Local address.** With `fixture-server $PORT` running, the same with `127.0.0.1:$PORT/c.html`: `wait-title "Page C"`, and the page's `url` in `trails.json` starts `http://`.
- **Search.** The same with `rust lifetimes`: `wait-title "rust lifetimes" 8` (Google's results title).
- **Cap.** `menu File "New Trail"`, `set` an address, `confirm`, twice: three trails. A fourth: `value mako.omnibox.status | head -1` is `Can’t open: trail cap reached (3). ⌥⌘T opens a page in the current trail.` and `trails.json` still has three roots.
- **Dismiss.** `menu File "Open Location…"; set mako.omnibox.field ""; confirm mako.omnibox.field`: the panel closes and the title is unchanged. `menu File "New Trail"; set mako.omnibox.field "$U/c.html"; press-id mako.omnibox.scrim`: `exists mako.omnibox` exits 4 and `trails.json` is unchanged. **(focus)** `key cmd+l; type zzz; key escape`: title unchanged. `scripts/sidebar-headed` clicks the page and a sidebar row with the omnibox open, and switches apps.
- **On its own.** `$C stop; $C launch` (no address): `title` is `Mako`, `exists mako.blank` exits 0, the field's `desc` starts `New trail` and `exists mako.omnibox.status` exits 4.
- **Proof.** `$M $P tree 6 > $E/omni-tree.txt; $M $P shot $E/omni.png` with the panel open. `trails-ax` keeps `omnibox-white-page.png`, `omnibox-dark-page.png` (`fixtures/trails/dark.html`) and `omnibox-cap-error.png`.

## Gotchas

- `mako.omnibox*` elements leave the AX tree while the panel is hidden (`exists` exits 4), so `exists mako.omnibox` proves the panel is showing.
- `v1.2`-style input is treated as search, not a domain, by design (the top-level domain must be letters).
- `set` changes the field without the typing notification, and the font is refit on typing (from source), so judge `omni-one-line` from typed input, as `ux-headed` does.
- `exists mako.omnibox.status` exiting 4 is the no-message state, so read a message with `value` only right after the action that set it.
