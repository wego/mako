# Blocklist

Pages from hosts in the config's `block` lines do not load; the page shows a "Not now." notice with the reason instead (`x.com is blocked. Back to work.`). The check runs on every main-frame navigation: addresses entered in the omnibox, link clicks (the link still opens its child page, and the notice shows there), redirects, reloads, restored pages, and addresses passed at launch or from another app. A blocked iframe (an embedded video, say) is left empty while the page around it loads. A download from a blocked host is cancelled, and a blocked host's site icon is never fetched. Images and scripts fetched from a blocked domain are not navigations and still load. Mako reads the config on every check, so edits apply on the next navigation.

## Sub-features

- `block-typed` an address entered for a blocked host shows the notice in that page.
- `block-subdomain` subdomains of a blocked domain are blocked; a leading `*.` in the rule, letter case and a trailing dot make no difference.
- `block-allowed` an unlisted host loads normally.
- `block-link` a link to a blocked host opens a child page showing the notice (`trails-bg` checks it).
- `block-iframe` an iframe from a blocked host stays empty; the host page and other iframes load.
- `block-launch` a blocked address passed at launch opens a trail showing the notice.
- `block-window` `block <domain> HH:MM-HH:MM [days]` blocks only inside the window, which may pass midnight. Days are `mon`…`sun`, ranges (`mon-fri`), lists (`sat,sun`), `weekdays`, `weekends` or `daily`; none means every day. The reason then says `until HH:MM.` or `until midnight.`.
- `block-live-edit` adding a `block` line takes effect on the next navigation, without a restart.
- `block-bad-config` a config line Mako cannot use costs only that line: every other line still applies. A `block` line whose time range or days are unusable blocks its domain at all times (reason `<domain> is blocked.`, no `until`). The first issue shows at the sidebar's foot (`mako.sidebar.config`, ``⚠ config line <n>: <problem>: `<line>` ``, ` (and <k> more)` when there are several) and as the omnibox status's first line; a click on the note opens the config file. A leftover `max_tabs` line is ignored silently and `max_trails` above 9 is clamped. Any saved edit redraws the note within a moment, whether the editor renames a new file over the config or writes it in place. `trails-bg` runs under a config with a typo key and a bad schedule; `trails-ax` adds `colour = red` both ways while Mako runs and removes it again.
- `block-download` a download link or response from a blocked host saves nothing.
- `block-favicon` no icon request goes to a blocked host, redirects included (`trails-bg` checks it).

## How to get to it (user POV)

- Enter a blocked address in the omnibox, or follow a link to one.
- Open a blocked link from another app (a launch argument here).
- Edit `~/.config/mako/config` (Mako → Edit Config File…, ⌘,), here the run's `MAKO_CONFIG`.

## Driving it with makoctl

Preconditions: baseline (`block x.com`); `MAKO_BACKGROUND=1` is fine for every step. Start `log stream --level info --predicate 'subsystem == "com.wego.mako"' --style compact > $E/block-log.txt &` first. `go() { $M $P menu File "Open Location…"; sleep 0.3; $M $P set mako.omnibox.field "$1"; $M $P confirm mako.omnibox.field; sleep 2; }` loads an address in the shown page.

- **Blocked.** `$C launch "" https://example.com`, `wait-title "Example Domain" 8`, then `go x.com`. `$M $P text` prints `Not now.` and `x.com is blocked. Back to work.`; `shot $E/block-page.png`. The log has `block x.com: x.com is blocked.`
- **Subdomain.** `go mobile.x.com`. Same text; the log has `block mobile.x.com: x.com is blocked.`
- **Allowed.** `go example.com`. `wait-title "Example Domain" 8`; the log has `allow https://example.com/`.
- **Iframe.** `go "data:text/html,<title>embed</title><p>host page</p><iframe src='https://x.com/'></iframe><iframe src='https://www.iana.org/'></iframe>"`. `wait-title embed`; the log has `block x.com (frame): x.com is blocked.` and `allow https://www.iana.org/`.
- **Live edit.** On example.com, `echo 'block example.com' >> verify-runs/latest/state/config`, then `$M $P menu View Reload`. `text` shows `example.com is blocked.`
- **Launch.** `$C stop; $C launch "" https://x.com`. `text` shows the notice.
- **Time window.** `printf 'block example.com 00:00-24:00 daily\n' > $E/window.config; $C stop; $C launch $E/window.config https://example.com`. `text` shows `example.com is blocked until midnight.`
- **Bad config lines.** `printf 'max_trails = 3\ncolour = red\nblock x.com\nblock example.com 09:00-25:00\n' > $E/bad.config; $C stop; $C launch $E/bad.config https://x.com https://example.com`. The log has `block x.com: x.com is blocked.` and `block example.com: example.com is blocked.` (no `until`: the bad schedule blocks at all times). `value mako.sidebar.config` is ``⚠ config line 2: unknown setting: `colour = red` (and 1 more)``; `shot` shows it at the sidebar's foot. `menu File "Open Location…"`: `value mako.omnibox.status | head -1` is the same text without `⚠ `. Write a valid config (`block example.com 09:00-17:00`): with no other action, `exists mako.sidebar.config` exits 4 within 2 s, and `go example.com` logs `example.com is blocked until 17:00.` inside the window.
- **Proof.** The log file in order, `text` after each step, `shot` of the notice.

## Gotchas

- Assert on the notice's text (`text`, or the log), not the window title. The notice is not an http page, so the trail keeps its last address and label: typing a blocked address over example.com leaves the row and title at `Example Domain`, and a blocked page opened as a trail or a link shows its address as its label (from source; confirm in a run).
- Block reasons with time windows say `until HH:MM` or `until midnight`; match `is blocked`.
- A notice page opened at launch in a background run can stay blank: `text` prints `no page content` and `shot` shows an empty page, with a valid config too (seen 2026-11-13). The log is the proof there.
- `log stream` must start before the action or the lines are missed.
- Each notice page logs an extra `allow about:blank`; assert on the order of the `block` and `allow https` lines, not the full log.
- Mako fills in `https://` for a bare domain, so the log shows the full address.
