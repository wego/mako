---
name: verify-mako
description: Drive the Mako macOS browser (Swift/AppKit + WKWebView, Rust core) the way a user does and capture proof. Use after any change to app/ or core/, before claiming a Mako feature works, or when asked to verify, screenshot, or test Mako's UI, shortcuts, tabs, blocklist, or accessibility tree.
---

# Verify Mako

Mako is a single-window macOS app. Agents drive it through the macOS accessibility (AX) API and per-process keyboard events, by PID, against an isolated instance built from this checkout. Never drive the user's own Mako (the one in /Applications or any instance this run did not launch): it holds their real tabs.

All commands run from the repo root. `C=.claude/skills/verify-mako/scripts/control-mako`.

## Requirements

The terminal running the agent needs macOS Accessibility and Screen Recording permission (System Settings → Privacy & Security). `doctor` fails loudly when either is missing. While the screen is locked, macOS degrades AX for every client: each app reports itself as its own window. `doctor` then prints `accessibility degraded: the screen is locked`; ask the user to unlock and retry. If it prints the same failure with the screen unlocked, the grant itself went stale; only the user can fix that, by toggling the terminal off and on in Accessibility and restarting it. Stop and ask either way; do not retry in a loop. Rust (`cargo`) and Swift toolchains must be installed.

## Launch

```sh
$C build                        # script/bundle (Rust release lib + Swift app) + compiles makoctl
$C launch                       # default disposable config: max_tabs = 3, block x.com
$C launch "" https://example.com             # default config, start URL
$C launch path/to/config https://example.com   # custom config and start URLs
P=$($C pid); M=verify-runs/.bin/makoctl
```

Ready when `launch` prints `pid <n> ready`. Launch goes through LaunchServices (`open -n --env`); a bare exec of the binary receives no key events. Each run drives its own app copy with bundle ID `com.wego.mako.verify.<run>`, so it shares no cookies, logins, caches or preferences with the user's Mako or other runs (see `docs/control.md`, Isolation). The instance uses `MAKO_CONFIG=verify-runs/latest/state/config`, so the user's `~/.config/mako/config` is never read or written. Set `MAKO_RUN=verify-runs/<name>` to keep evidence from separate runs apart. Only one instance per `MAKO_RUN`; `launch` refuses a second.

`launch` always starts from fresh state: default config, no `session.json`, so nothing is restored. `$C quit` (graceful ⌘Q, keeps state) and `$C relaunch [url...]` (start again on the same state) exercise session restore.

## Doctor

```sh
$C doctor
```

Prints `OK pid … build <mtime> title "…"` only when the PID is alive, is this checkout's `build/Mako.app` binary, answers AX queries, and can be screenshotted. Run it first, and again whenever a step behaves oddly.

## Drive

Full command reference, exit codes, AX handles, and recipes: `docs/control.md`. Any new `makoctl` or `control-mako` command must be added there; `scripts/doc-check` (run by `smoke`) fails otherwise.

`makoctl <pid> <command>` (run `$M` with no args for the full list):

| Command | Use |
| --- | --- |
| `tree [depth] [--menus]` | AX tree snapshot; the primary evidence of UI state |
| `title` / `wait-title <substr> [s]` | window AX title: page label + ` – i/n` (macOS joins `window.title` and `window.subtitle` in the AX title; verified live) |
| `value <id>` / `exists <id>` | read an element by AX identifier |
| `menu <Menu> <Item>` / `menu-items <Menu>` | press or list menu items via AX |
| `key <combo>` | `return`, `escape`, `cmd+a`, `cmd+c`, `cmd+v`, `cmd+x`, `cmd+opt+c`, `cmd+t`, `cmd+w`, `cmd+l`, `cmd+1`…`cmd+9`, `cmd+z`, `cmd+[`, `cmd+]`, `cmd+r` |
| `type <text>` | types into the focused element |
| `time-key <combo> <substr>` | ms from key press to the title containing substr (perf timing) |
| `shot <path>` | window screenshot (works even when another app is in front) |

Stable AX handles: window title; `mako.page` (web container), `mako.omnibox` (address bar panel), `mako.omnibox.field` (its text field, value = typed text), `mako.omnibox.status` (tab list and messages), `mako.blank` (new-tab icon), `mako.tab.<n>` (each tab's web view, 1-based). The `Tabs` menu lists one item per open tab titled with the tab's label; the active one is checked.

`key`, `type`, and `menu` first activate the target PID: a background app has no key window, so keys and menu actions would be dropped. Driving therefore takes focus from whatever the user is doing; warn them before a run and do not drive while they type. Menus are read and pressed without opening them, because an open menu swallows every later key. Allow ~0.4 s after a key before reading state, or use `wait-title`.

## Evidence

Write artifacts to `$MAKO_RUN/evidence/` (default `verify-runs/latest/evidence/`), named `<feature-id>-<step>.{txt,png}`. Proof standards:

- Drive the real user path: menus, shortcuts, and typing. No internal setters.
- Capture the action and the resulting state: a `tree` or `title` read after each step, plus a `shot` for anything visual.
- For the blocklist, prove both sides: a blocked host shows the block page and an unblocked host loads.
- `log stream --level info --predicate 'subsystem == "com.wego.mako"'` shows `allow`/`block`/`loaded` decisions; capture it alongside UI evidence for navigation proofs.
- A pass needs every step's expected observation; "it didn't crash" is not a pass.

## Cleanup

```sh
$C stop
```

Kills only the PID this run launched and removes `$MAKO_RUN/state` and the run's website data. Evidence in `$MAKO_RUN/evidence/` survives. Run `stop` after every failed attempt too.

## Full pass

```sh
.claude/skills/verify-mako/scripts/smoke
```

Builds, then runs every `features/*.md` recipe against fresh instances, then `scripts/perf`: one `PASS`/`FAIL` line per check, exit status = failure count, evidence in `verify-runs/latest/evidence/`. It takes focus for about 2 minutes. Run it before claiming any Mako change works; drive a single recipe by hand when debugging one failure.

## Performance budgets

```sh
.claude/skills/verify-mako/scripts/perf
```

`PERF_N` (default 8) fresh launches on local `data:` pages. Primary numbers come from inside Mako (`MAKO_PERF=1`, set by `control-mako`): launch to interactive (process start until the main thread first idles), launch to first page, and ⌘T / ⌘1 from input event until the main thread idles. Also memory with 3 tabs, bundle size, and the Rust core's per-navigation parse+check. Budgets live at the top of the script, about 1.5× measured medians; `perf.log` in the evidence dir keeps a line per run. A miss is a regression to fix, not a budget to raise; raise one only with a stated reason in the commit. To decide whether a change is faster, use `scripts/ab <base> <candidate>` (paired, interleaved), not two `perf` runs.

## Feature map

`features/README.md` indexes one recipe per user-facing feature. Drive every entry point a feature lists, not just the convenient one. Keep the map current with `/maintain-verification-skill`.
