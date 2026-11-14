# Mako verification map

One recipe per user-facing feature. Read this index, then drive the matching file.

## Baseline preconditions

- `control-mako build` ran against the current checkout.
- `control-mako launch` started a fresh instance with the default disposable config (`max_trails = 3`, `block x.com`) unless a recipe says otherwise. Fresh means no `trails.json`, so only the launch addresses are open, each as a trail.
- `control-mako doctor` prints `OK`.
- `P=$(control-mako pid)`, `M=verify-runs/.bin/makoctl` and `E=verify-runs/latest/evidence` are set.
- Most recipes serve local fixtures (`scripts/fixture-server $PORT &` for `fixtures/trails/`, `python3 -m http.server` for the others) as `U=http://127.0.0.1:$PORT`. A few need network access to `example.com`, `www.iana.org` or `www.google.com`.

## Driving conventions

- Every recipe starts from a fresh launch. Run `control-mako stop` then `launch` between recipes that change the trails or the config.
- Prefer `MAKO_BACKGROUND=1` and the AX commands (`menu`, `press-id`, `press`, `set`, `confirm`, and the reads); they work while the person uses the Mac. A step marked **(focus)** needs a headed run because it proves a real key press or pointer click.
- Address elements by AX identifier or menu title, never by coordinates (the middle-clicks on fixture targets in `ux-headed` are the exception).
- Read state after every action (`title`, `value`, `tree`, `trails.json`), not only at the end.

## Proof and skip reporting

- UI proof is an AX `tree` capture plus a `shot`, both under `verify-runs/<run>/evidence/`; for the tree of pages, `trails.json`.
- Navigation proof adds the `com.wego.mako` log lines for the same run.
- Report an unreachable step with the command run and the unmet precondition. Never report a skipped entry point as verified through another one.

## Feature entry contract

Each file: H1 title, one paragraph of user-visible behavior, then `Sub-features`, `How to get to it (user POV)`, `Driving it with makoctl`, `Gotchas`.

## Features

- [Window](./window.md) covers the chromeless window: the traffic lights on the sidebar, moving the window by the sidebar's paper or the top strip, title-bar double-clicks, hiding the sidebar (⌃⌘S) and peeking it from the left edge.
- [Trails](./trails.md) covers the sidebar's trees of pages: links opening child pages, the trail cap, select, the hover × and toggle, ⌘1…⌘9 jumps, close, Undo Close, collapse, moves, rename, middle-clicks, colours, site icons, width, find, downloads.
- [Omnibox](./omnibox.md) covers address entry, search, suggestions from open pages and history, what Enter does for ⌘L, ⌘T, ⌥⌘T and ⌘F, the scrim and ring that mark it open, the error line, and dismissal (Escape or a click outside).
- [History](./history.md) covers recording visits in `history.json`, what counts as a visit, the cap, `remember_history = false` and Clear History….
- [Settings](./settings.md) covers the ⌘. window and its trail cap.
- [Session restore](./session.md) covers saving `trails.json` on every change, restoring at launch, links at launch, turning it off, migration and unreadable files.
- [Blocklist](./blocklist.md) covers blocked and allowed hosts, time windows, iframes, live config edits and config errors.
- [Page dialogs](./dialogs.md) covers `alert()`, `confirm()` and `prompt()` sheets, answering them, and silencing.
- [Sign-in popups](./popups.md) covers OAuth-style popups, `window.opener`, `target=_blank` links, and the user agent.
- [Navigation and zoom](./navigation.md) covers back, forward, reload, and zoom.
- [Page shortcuts](./page-shortcuts.md) covers which keys reach Mako and which reach web pages first.
- [Developer console](./devtools.md) covers opening, using, and closing the Web Inspector.
- [Accessibility tree](./accessibility.md) covers the handles and actions agents rely on.
