# Blocklist

Pages from hosts in the config's `block` lines (with optional time windows) do not load; Mako shows a "Not now." page instead. The check runs on every main-frame navigation: typed URLs, link clicks, redirects, restored tabs, and URLs passed at launch. A blocked host embedded in an iframe on another site still loads. Config edits apply on the next navigation.

## Sub-features

- `block-typed` a typed blocked host shows the block page.
- `block-subdomain` subdomains of a blocked domain are blocked.
- `block-allowed` an unlisted host loads normally.
- `block-live-edit` adding a `block` line takes effect without restart.

## How to get to it (user POV)

- Type a blocked address in the omnibox.
- Open a blocked link from another app (launch argument).
- Edit `~/.config/mako/config` (⌘,), here the run's `MAKO_CONFIG`.

## Driving it with makoctl

Preconditions: baseline (`block x.com`). Start `log stream --level info --predicate 'subsystem == "com.chuyeow.mako"' > $E/block-log.txt &` first.

- **Blocked.** `$M $P key cmd+l; $M $P type x.com; $M $P key return`. `$M $P tree 8 | grep "x.com is blocked"` matches; `shot $E/block-page.png`.
- **Subdomain.** Same with `mobile.x.com`. Same text.
- **Allowed.** Same with `example.com`. `wait-title "Example Domain"`.
- **Live edit.** `echo 'block example.com' >> verify-runs/latest/state/config`, then `$M $P key cmd+r`. Tree shows `example.com is blocked.`
- **Proof.** The log file shows `block x.com`, `block mobile.x.com`, `allow https://example.com/`, then `block example.com`.

## Gotchas

- Block reasons with time windows say `until HH:MM` or `until midnight`; assert on `is blocked`.
- `log stream` must start before the action or the lines are missed.
- Each block page itself logs an extra `allow about:blank`; assert on the order of the `block`/`allow https` lines, not the full log.
