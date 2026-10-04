# Mako verification map

One recipe per user-facing feature. Read this index, then drive the matching file.

## Baseline preconditions

- `control-mako build` ran against the current checkout.
- `control-mako launch` started a fresh instance with the default disposable config (`max_tabs = 3`, `block x.com`) unless a recipe says otherwise. Fresh means no saved session, so only the launch URL is open.
- `control-mako doctor` prints `OK`.
- `P=$(control-mako pid)` and `M=verify-runs/.bin/makoctl` are set.
- Network access to `example.com` and `www.google.com`.

## Driving conventions

- Every recipe starts from a fresh launch. Run `control-mako stop` then `launch` between recipes that mutate tabs.
- Address elements by AX identifier or menu title, never by coordinates.
- Read state after every action (`title`, `value`, `tree`), not only at the end.

## Proof and skip reporting

- UI proof is an AX `tree` capture plus a `shot`, both under `verify-runs/<run>/evidence/`.
- Navigation proof adds the `com.wego.mako` log lines for the same run.
- Report an unreachable step with the command run and the unmet precondition. Never report a skipped entry point as verified through another one.

## Feature entry contract

Each file: H1 title, one paragraph of user-visible behavior, then `Sub-features`, `How to get to it (user POV)`, `Driving it with makoctl`, `Gotchas`.

## Features

- [Omnibox](./omnibox.md) covers address entry, search, and dismissal.
- [Tabs](./tabs.md) covers new, switch, close, the tab cap, title bar, and the blank-tab icon.
- [Blocklist](./blocklist.md) covers blocked and allowed hosts and live config edits.
- [Accessibility tree](./accessibility.md) covers the handles agents rely on.
- [Page shortcuts](./page-shortcuts.md) covers which ⌘ keys reach web pages.
- [Developer console](./devtools.md) covers opening, using, and closing the Web Inspector.
- [Session restore](./session.md) covers saving at quit, restoring at launch, and turning it off.
- [Navigation and zoom](./navigation.md) covers back, forward, reload, and zoom.
- [Sign-in popups](./popups.md) covers OAuth-style popups, `window.opener`, `target=_blank` links, and the user agent.
