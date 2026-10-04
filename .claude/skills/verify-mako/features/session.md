# Session restore

Quitting Mako remembers its open pages and which tab was active; the next launch reopens them. Blank, blocked, and error tabs are not remembered. `restore_session = false` in the config turns this off and deletes the saved session.

## Sub-features

- `session-save` quitting writes the open http(s) tabs and the active one.
- `session-restore` launching reopens them, capped at `max_tabs`, with the same active tab.
- `session-plus-link` opening Mako with a link restores the session and adds the link as a tab; if restored tabs already fill `max_tabs`, the link prefills the omnibox with the cap prompt instead.
- `session-off` `restore_session = false` starts with one blank tab and removes the saved session at quit.

## How to get to it (user POV)

- Quit with ⌘Q (or close the window), then open Mako again.
- Open a link in Mako while it is not running.
- Add `restore_session = false` to the config (⌘,).

## Driving it with makoctl

Preconditions: baseline launched with `https://example.com`. The session file is `verify-runs/<run>/state/session.json`, beside the run's config.

- **Build a session.** `$M $P key cmd+t; $M $P type iana.org; $M $P key return; $M $P wait-title "Internet Assigned Numbers Authority" 8`, then `$M $P key cmd+t; $M $P key escape; $M $P key cmd+1`. `menu-items Tabs` shows `* Example Domain`, `Internet Assigned Numbers Authority`, `New Tab`.
- **Quit.** `$C quit`. `cat verify-runs/latest/state/session.json` shows the two https URLs (no blank tab) and `"active":0`.
- **Restore.** `$C relaunch; P=$($C pid)`. `wait-title "Example Domain – 1/2"`; `menu-items Tabs` lists both pages.
- **Restore + link.** `$M $P key cmd+2; $C quit; $C relaunch https://example.org; P=$($C pid)`. `wait-title "– 3/3"`; the link is the active third tab.
- **Off.** `echo 'restore_session = false' >> verify-runs/latest/state/config; $C quit; $C relaunch; P=$($C pid)`. `wait-title "New Tab – 1/1"`. `$C quit`; `session.json` no longer exists.
- **Proof.** Append each `title`, `menu-items Tabs`, and `session.json` read to `$E/session.txt`; `shot $E/session-restored.png` after the restore.

## Gotchas

- Only a graceful quit saves. `$C stop` kills the process and wipes the state dir, so use `$C quit` + `$C relaunch` here.
- A JSON reader may reorder keys (`active` before `tabs`); compare values, not the raw string.
- Restored tabs start loading immediately; wait on the title before switching tabs.
- A blank active tab at quit saves `"active":0`.
- A config that fails to parse falls back to defaults, so restore stays on.
