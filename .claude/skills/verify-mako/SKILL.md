---
name: verify-mako
description: Drive the Mako macOS browser (Swift/AppKit + WKWebView, Rust core) the way a user does and capture proof. Use after any change to app/ or core/, before claiming a Mako feature works, or when asked to verify, screenshot, or test Mako's UI, trails and sidebar, shortcuts, omnibox, settings, blocklist, page dialogs, or accessibility tree.
---

# Verify Mako

Mako is a single-window macOS browser: a sidebar of trails, each a tree of pages, beside the active page. Agents drive it through the macOS accessibility (AX) API and per-process keyboard and pointer events, by PID, against an isolated instance built from this checkout. Never drive the user's own Mako (the one in /Applications or any instance this run did not launch): it holds their real trails.

All commands run from the repo root. `C=.claude/skills/verify-mako/scripts/control-mako`.

## Requirements

The terminal running the agent needs macOS Accessibility and Screen Recording permission (System Settings → Privacy & Security). `doctor` fails loudly when either is missing. While the screen is locked, macOS degrades AX for every client: each app reports itself as its own window. Every `makoctl` command except `shot` then exits 8 with `accessibility degraded: the screen is locked`; ask the user to unlock and retry. If it prints the same failure with the screen unlocked, the grant itself went stale; only the user can fix that, by toggling the terminal off and on in Accessibility and restarting it. Stop and ask either way; do not retry in a loop. Rust (`cargo`) and Swift toolchains must be installed.

## Launch

```sh
$C build                        # script/bundle (Rust release lib + Swift app) + compiles makoctl
$C launch                       # default disposable config: max_trails = 3, block x.com
$C launch "" https://example.com             # default config, start URL
$C launch path/to/config https://example.com   # custom config and start URLs
P=$($C pid); M=verify-runs/.bin/makoctl
```

Ready when `launch` prints `pid <n> ready`. Launch goes through LaunchServices (`open -n --env`); a bare exec of the binary receives no key events. Each run drives its own app copy with bundle ID `com.wego.mako.verify.<run>`, so it shares no cookies, logins, caches or preferences with the user's Mako or other runs (see `docs/control.md`, Isolation). The instance uses `MAKO_CONFIG=verify-runs/<run>/state/config`, so the user's `~/.config/mako/config` is never read or written. Set `MAKO_RUN=verify-runs/<name>` to keep evidence from separate runs apart (default `verify-runs/latest`). Only one instance per `MAKO_RUN`; `launch` refuses a second.

`launch` always starts from fresh state: default config, no `trails.json`, no website data, so nothing is restored and the omnibox opens for a first trail. Each launch URL opens as a trail of its own (beneath the active page once the trail cap is reached). Mako saves `state/trails.json` after every change; `$C relaunch [url...]` starts again on that state, as a person reopening Mako would. `$C quit` presses Mako → Quit Mako and waits for the exit. With `MAKO_BACKGROUND=1` it sends SIGTERM instead, which ends Mako without `applicationWillTerminate` (inferred from source: AppKit installs no SIGTERM handler), so a background quit does not delete `trails.json` under `restore_session = false`.

## In the background or headed

Set `MAKO_BACKGROUND=1` whenever the person is using the Mac. `launch` then starts the test copy behind every other window, Mako never activates itself, and `makoctl` refuses the commands that need focus (`key`, `type`, `time-key`, `click-id`, `middle-click-id`, `middle-click`) with exit 9. Everything else works through AX without focus: `menu`, `press`, `press-id`, `set`, `confirm`, and every read. Recipes use these wherever they can; a step marked **(focus)** needs a headed run, because it proves a real key press, typing into a page, or a real pointer click.

Without `MAKO_BACKGROUND`, `key`, `type`, `menu`, `press`, `time-key` and the clicks first bring Mako to the front (exit 7 if another app keeps focus), so a headed run takes focus from whatever the user is doing: warn them first and do not drive while they type. Menus are read and pressed without opening them, because an open menu swallows every later key. Allow ~0.4 s after an action before reading state, or use `wait-title`.

## Doctor

```sh
$C doctor
```

Prints `OK pid … build <mtime> title "…"` only when the PID is alive, is this run's copy of this checkout's `build/Mako.app`, answers AX queries, and can be screenshotted. Run it first, and again whenever a step behaves oddly.

## Drive

Full command reference, exit codes, AX handles, and recipes: `docs/control.md`. Any new `makoctl` or `control-mako` command must be added there; `scripts/doc-check` (run by `smoke`) fails otherwise.

`makoctl <pid> <command>` (run `$M` with no args for the full list):

| Command | Use |
| --- | --- |
| `tree [depth] [--menus]` | AX tree snapshot; the primary evidence of UI state |
| `title` / `wait-title <substr> [s]` | window AX title: the active page's label (its name, else its title, else its address), or `Mako` with no page open |
| `value <id>` / `exists <id>` / `frame <id>` | read an element by AX identifier: its value, whether it is in the tree, its frame |
| `text` | the active page's visible text, untruncated |
| `windows` | one line per window: the main window, Settings, sign-in popups (`id="mako.popup"`) |
| `menu <Menu> <Item>` / `menu-items <Menu>` | press or list menu items via AX |
| `press-id <id>` / `press <name>` | AX press by identifier (sidebar rows, toggles, dialog buttons) or by title (web buttons and links) |
| `set <id> <text>` / `confirm <id>` | set a field's value, then Enter, through AX: the omnibox, a rename field, Settings, a prompt dialog, the sidebar width |
| `key <combo>` / `type <text>` (focus) | real keys; modifiers `cmd`, `shift`, `opt`, `ctrl`; keys listed in `docs/control.md` |
| `click-id <id> [fx fy]` / `middle-click-id <id>` / `middle-click <x> <y>` (focus) | real pointer clicks; they move the user's pointer |
| `time-key <combo> <substr>` (focus) | ms from key press to the title containing substr |
| `shot <path>` | window screenshot (works even when other windows cover it) |
| `pointer-center` | parks the pointer over the page, for perf runs |

Stable AX handles (full table in `docs/control.md`): `mako.sidebar` (the trails list), `mako.trail.<id>` (a sidebar row; `id` is the page's permanent id from `trails.json`, value `selected` on the active page), `mako.trail.<id>.toggle` (collapse control), `mako.trail.<id>.name` (rename field), `mako.trail.<id>.page` (a loaded page's web view), `mako.sidebar.load` (the `🧠 n/max` note, present only at the trail cap), `mako.divider` (sidebar width), `mako.page` (web container), `mako.omnibox`, `mako.omnibox.field`, `mako.omnibox.status` (error, what Enter does, trail and page counts), `mako.blank` (shown with no page), `mako.popup`, `mako.dialog.ok` / `.cancel` / `.field` / `.silence`, `mako.settings.maxTrails` and `.stepper`. The `Trails` menu has Next Page, Previous Page, the move items and Rename Page…, then one item per visible page, indented by depth, the active one checked; a trail's root item carries ⌘1…⌘9.

## Evidence

Write artifacts to `$MAKO_RUN/evidence/` (default `verify-runs/latest/evidence/`), named `<feature-id>-<step>.{txt,png}`. Proof standards:

- Drive the real user path: menus, shortcuts, typing, clicks, or the AX actions assistive tech uses (`press`, `set`, `confirm`). No internal setters.
- Capture the action and the resulting state: a `tree`, `title`, `value` or `trails.json` read after each step, plus a `shot` for anything visual.
- `state/trails.json` is the core's whole state, rewritten after every change: the most direct proof of the tree, the active page, the Undo Close stack and trail colours.
- For the blocklist, prove both sides: a blocked host shows the block notice and an unblocked host loads.
- `log stream --level info --predicate 'subsystem == "com.wego.mako"'` shows Mako's decisions (`allow`, `block`, `child of`, `loaded page`, `popup`, `favicon`, `dialog … dismissed`, `download to`, `trails <action> refused`); capture it alongside UI evidence for navigation proofs. Start it before the action.
- A pass needs every step's expected observation; "it didn't crash" is not a pass.

## Cleanup

```sh
$C stop
```

Kills only the PID this run launched and removes `$MAKO_RUN/state` and the run's website data. Evidence in `$MAKO_RUN/evidence/` survives. Run `stop` after every failed attempt too.

## Scripts

Each lives in `.claude/skills/verify-mako/scripts/` and runs from the repo root with no arguments unless shown. Each prints one `PASS`/`FAIL` line per check and exits with the number of failures (99 = could not build or launch). The check scripts build first; `MAKO_SKIP_BUILD=1` skips that when `build/` is current. `perf` and `ab` use the existing build.

| Script | Covers | Needs | Checks |
| --- | --- | --- | --- |
| `trails-bg` | links nest, in-place navigation, restart restore and lazy loading, external links and the trail cap, blocked links, form submits, trail colours, site icons, file links | nothing: no focus, no permissions | 24 |
| `trails-ax` | sidebar rows, collapse, Trails menu and ⌘1…⌘9 items, sidebar width, Settings, omnibox, trail cap and 🧠 note, close, Undo Close across a restart, moves, rename, find, deep rows at the narrowest sidebar | Accessibility | 53 |
| `dialogs-bg` | `alert()`, `confirm()`, `prompt()` wait for the person | nothing | 3 |
| `dialogs-ax` | answering dialogs, silencing, which navigations lift it | Accessibility | 17 |
| `isolation-ax` | a run's website data is invisible to another run; the daily Mako's data is untouched | Accessibility | 4 (the last is `SKIP` while the daily Mako runs) |
| `ux-headed` | middle-clicks on page content and sidebar rows, ⌘1 as a key, the omnibox with a long address, which icon each row shows | focus, Accessibility, Screen Recording | 24 |
| `settings-headed` | ⌘., stepper clicks, typed values, ⌘W | focus, Accessibility, Screen Recording | 12 |
| `perf` | performance budgets (below) | Accessibility; focus unless `MAKO_BACKGROUND=1` | 8 budgets (6 and a `SKIP` in the background) |
| `ab <base> <candidate> [rounds]` | paired A/B of in-app latency between two built checkouts | focus, Accessibility | – |
| `smoke` | the full pass (below) | as the scripts it runs | sum of the above |
| `doc-check` | `docs/control.md` lists every `makoctl` and `control-mako` command | nothing | 1 line |
| `fixture-server <port>` | serves `fixtures/trails/` on 127.0.0.1; its `/favicon.ico` answers after 3 s | nothing | – |

The background scripts are safe while the person uses the Mac; run `trails-bg` and `trails-ax` after any change to navigation, the tree or the sidebar, and the dialogs scripts after any change to `WKUIDelegate` code. Run the headed ones only when the user has handed the Mac over.

## Full pass

```sh
.claude/skills/verify-mako/scripts/smoke                  # background: never takes focus
SMOKE_HEADED=1 .claude/skills/verify-mako/scripts/smoke   # adds ux-headed, settings-headed and perf's key timings
```

Runs `doc-check`, builds once, then `trails-bg`, `trails-ax`, `dialogs-bg`, `dialogs-ax`, `isolation-ax`, the two headed scripts when `SMOKE_HEADED=1`, and `perf`. It prints every script's lines, then one `SUMMARY <script> <n> failure(s)` line each; exit status is the total. Evidence stays in `verify-runs/<script>/evidence/` (perf: `verify-runs/latest/evidence/`). Run it before claiming any Mako change works. The feature recipes in `features/` cover more than the scripts do; drive the matching recipe by hand for any feature a change touches, and a single recipe step when debugging one failure.

## Performance budgets

```sh
.claude/skills/verify-mako/scripts/perf
```

`PERF_N` (default 8) fresh launches on local `data:` pages. Primary numbers come from inside Mako (`MAKO_PERF=1`, set by `control-mako`): launch to interactive (process start until the main thread first idles), launch to first page, and ⌘T (New Trail) and ⌘1 (jump back to the first trail) from the key event until the main thread idles. Also memory with 3 trails, bundle size, and the Rust core's per-navigation parse+check. Mako times an action from the event that triggered it, so the ⌘T and ⌘1 budgets need real key presses: under `MAKO_BACKGROUND=1` perf takes no focus and prints `SKIP` for those two. Budgets live at the top of the script, about 1.5× measured medians; the ⌘T and ⌘1 budgets still carry the tabs-era numbers until re-measured. `perf.log` in the evidence dir keeps a line per run, with its mode. A miss is a regression to fix, not a budget to raise; raise one only with a stated reason in the commit. To decide whether a change is faster, use `scripts/ab <base> <candidate>` (paired, interleaved, headed), not two `perf` runs.

## Feature map

`features/README.md` indexes one recipe per user-facing feature. Drive every entry point a feature lists, not just the convenient one. Keep the map current with `/maintain-verification-skill`.
