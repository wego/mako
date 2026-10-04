# Controlling Mako from scripts and agents

Mako has no scripting API of its own. Everything a person can do, a script can do through two tools that drive the real app the way a user does: through macOS accessibility (AX) and keyboard events.

- **`control-mako`** starts, checks, quits, and stops an *isolated* Mako built from this checkout.
- **`makoctl`** drives one running Mako by process ID: reads its state, presses menus and buttons, types, takes screenshots.

Both live in `.claude/skills/verify-mako/scripts/`. The `verify-mako` skill uses them for verification; this page is the reference for anyone, human or agent, who wants to use them directly.

`scripts/doc-check` fails when a `makoctl` or `control-mako` command is missing from this page, and `smoke` runs it first. Adding a command means documenting it here.

## Setup

- macOS with the Rust and Swift toolchains installed.
- The terminal (or agent host) running the tools needs **Accessibility** and **Screen Recording** permission: System Settings → Privacy & Security.
- The screen must be unlocked. While it is locked, macOS hides every app's windows from AX and the tools fail with exit 8 (see [Troubleshooting](#troubleshooting)).

```sh
C=.claude/skills/verify-mako/scripts/control-mako
M=verify-runs/.bin/makoctl

$C build                              # build/Mako.app + compile makoctl
$C launch "" https://example.com      # isolated instance, prints its pid
P=$($C pid)
$M $P title                           # "Example Domain – 1/1"
$C stop
```

## Isolation: which Mako you are driving

`control-mako` never touches the Mako you use day to day.

- Each run drives its own copy of the build, `verify-runs/<run>/app/Mako.app`, with its own bundle ID, `com.wego.mako.verify.<run>`. macOS and WebKit store cookies, logins, caches, local storage, preferences and window positions by bundle ID, so a run shares none of them with your daily Mako or with other runs. A run is never signed in to anything you are.
- The copy has no `http`/`https` URL handlers, so macOS never offers it for links you open. It is re-signed ad hoc, so it never carries the passkey entitlement even when the daily build does.
- `launch` starts the run with no website data; `stop` deletes that data (`~/Library/{WebKit,Caches,HTTPStorages,Preferences}/com.wego.mako.verify.<run>*`). Data persists across `quit` and `relaunch` within a run.
- `MAKO_CONFIG` points at `verify-runs/<run>/state/config`, so your `~/.config/mako/config` and `session.json` are never read or written.
- `makoctl` targets a process ID, never an app name, so it cannot reach another Mako by accident.

`smoke` proves this on every run: a cookie set in one run is invisible to a second run, and your daily Mako's data files are unchanged afterwards.

`MAKO_RUN=verify-runs/<name>` keeps separate runs apart (default `verify-runs/latest`). Each run has `state/` (config, `session.json`, pid; deleted by `stop`) and `evidence/` (screenshots and logs; never deleted by the tools).

## control-mako

| Command | What it does |
| --- | --- |
| `control-mako build` | Runs `script/bundle` (Rust core + Swift app) and compiles `makoctl` into `verify-runs/.bin/`. |
| `control-mako launch [config-file\|""] [url...]` | Fresh state (config, session, and website data), then start the run's own app copy. `""` uses the default test config (`max_tabs = 3`, `block x.com`); a file path copies that config. URLs open at launch. Refuses if this run already has a live instance. Prints `pid <n> ready`. |
| `control-mako pid` | Prints the running instance's pid. |
| `control-mako doctor` | Read-only health check: process alive, it is this checkout's build, AX answers, screenshots work. Prints `OK …` or `FAIL <reason>`. Run it first and after anything surprising. |
| `control-mako quit` | Graceful ⌘Q through the menu, so Mako saves its session. Waits for exit. Keeps `state/`. |
| `control-mako relaunch [url...]` | Starts again on the existing `state/` (config and `session.json`), as a user reopening Mako would. |
| `control-mako stop` | Kills the instance this run started, deletes `state/` and the run's website data. Evidence stays. |

Exit status is 0 on success, 1 on failure, 64 on bad usage.

## makoctl

Every command is `makoctl <pid> <command> [args]`. Commands that send input (`key`, `type`, `menu`, `press`, `time-key`) first bring Mako to the front: a background app has no key window, so input sent to it is dropped. Read-only commands work with Mako in the background.

### Reading state

| Command | Output |
| --- | --- |
| `makoctl <pid> title` | The window's AX title: page label + ` – <tab>/<tabs>`, e.g. `Example Domain – 1/3`. Page label is the page title, else the host, else `New Tab`. |
| `makoctl <pid> wait-title <substring> [seconds]` | Polls every 50 ms until the title contains the substring (default 10 s). Prints the title; exit 5 on timeout. The standard way to wait for a page load or tab change. |
| `makoctl <pid> tree [depth] [--menus]` | The AX tree, one element per line: role, subrole, `id=`, `title=`, `desc=`, `value=`. Default depth 12. Web page content appears under `AXWebArea`. `--menus` includes the menu bar. |
| `makoctl <pid> value <ax-identifier>` | The `AXValue` of the element with that identifier, e.g. the omnibox text. Exit 4 if absent. |
| `makoctl <pid> exists <ax-identifier>` | Exit 0 if an element with that identifier is in the tree, 4 otherwise. Hidden elements can still exist; use `shot` to prove visibility. |
| `makoctl <pid> text` | The active page's visible text, untruncated, one line per text run (`tree` shortens values to 80 characters). |
| `makoctl <pid> menu-items <Menu>` | One line per item in a menu bar menu; the checked item starts with `*`. `menu-items Tabs` lists open tabs with the active one checked. Does not open the menu. |
| `makoctl <pid> windows` | One line per window. Sign-in popups carry `id="mako.popup"`. |
| `makoctl <pid> pointer-center` | Moves the mouse pointer over the middle of the page. Perf runs use it so cursor-update costs are measured the same way every time. Moves the user's real pointer. |
| `makoctl <pid> shot <path.png>` | Screenshot of Mako's main window, even if other apps cover it. Exit 6 without Screen Recording permission. |

### Acting

| Command | Effect |
| --- | --- |
| `makoctl <pid> key <combo>` | Presses a key. Modifiers `cmd`, `shift`, `opt` joined with `+`. Keys: `return`, `escape`, `tab`, `a`, `c`, `t`, `v`, `w`, `x`, `l`, `r`, `z`, `[`, `]`, `0`–`9`, `=`, `-`, `,`. Examples: `cmd+t`, `cmd+opt+c`, `escape`. Exit 64 for a key not in the table; add it to `keyCodes` in `makoctl.swift`. |
| `makoctl <pid> type <text>` | Types text into whatever has focus: the omnibox after `key cmd+l`, a web form field, the developer console. Any Unicode text works. |
| `makoctl <pid> menu <Menu> <Item>` | Presses a menu item by its exact titles, e.g. `menu File "New Tab"`, `menu Tabs "Example Domain"`, `menu View "Developer Console"`. Does not open the menu (an open menu would swallow later keys). |
| `makoctl <pid> press <name>` | Presses the first control whose title, description, or value equals `name`: web page buttons and links (`press "Continue with Google"`), as well as native controls. |

### Measuring

| Command | Output |
| --- | --- |
| `makoctl <pid> time-key <combo> <substring>` | Milliseconds from the key press until the title contains the substring, polling every 5 ms inside one process so tool start-up is not counted. Includes macOS's ~50 ms accessibility title delay, and the 5 ms polling itself loads Mako's main thread, so use Mako's in-app `MAKO_PERF` timings (`perf`, `ab`) to judge Mako's speed. Exit 5 after 5 s. |

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success. |
| 1 | No standard window found. |
| 2 | This terminal lacks Accessibility permission. |
| 3 | No process with that pid. |
| 4 | Element, menu, item, or window not found. The message lists what does exist. |
| 5 | `wait-title` / `time-key` timed out; the message shows the last title. |
| 6 | Screenshot failed: Screen Recording permission. |
| 7 | Could not bring Mako to the front: another app kept focus (usually someone typing). |
| 8 | AX degraded: the screen is locked, or with the screen unlocked, the terminal's Accessibility grant went stale. |
| 64 | Bad usage or unknown key. |

## AX handles

Stable identifiers Mako sets for automation. Prefer these, menu titles, and the window title over tree position or coordinates.

| Identifier | Element |
| --- | --- |
| `mako.page` | Container for the active tab's page. |
| `mako.tab.<n>` | Each tab's web view, 1-based in tab order. Its `AXWebArea` child holds the page content. |
| `mako.omnibox` | The address bar panel (present while hidden). |
| `mako.omnibox.field` | Its text field; `value` is the text in it. |
| `mako.omnibox.status` | The line under the field: tab list, `n/max tabs`, tab-cap and config-error messages. |
| `mako.blank` | The app icon shown on a blank tab. |
| `mako.popup` | A sign-in popup window. |

Menu bar: `File` (New Tab, Open Location…, Close Tab), `Edit`, `View` (Reload, Zoom In/Out, Actual Size, Developer Console), `History` (Back, Forward), `Tabs` (one item per open tab).

## Recipes

Open a URL in the current tab:

```sh
$M $P key cmd+l; $M $P type "https://example.com"; $M $P key return
$M $P wait-title "Example Domain"
```

Open a URL in a new tab:

```sh
$M $P key cmd+t; $M $P type "news.ycombinator.com"; $M $P key return
$M $P wait-title "Hacker News"
```

List tabs and switch to one by name:

```sh
$M $P menu-items Tabs
$M $P menu Tabs "Hacker News"
```

Read the visible text of the current page:

```sh
$M $P text
```

Click a link or button on a page:

```sh
$M $P press "Learn more"
$M $P wait-title "Example Domains"      # the IANA page it leads to
```

Run JavaScript in the page and read the result through the title:

```sh
$M $P key cmd+opt+c                     # developer console; focus is in its prompt
$M $P type 'document.title = String(document.links.length)'; $M $P key return
$M $P title
```

Test a session restore:

```sh
$C quit; cat verify-runs/latest/state/session.json; $C relaunch; P=$($C pid)
```

Watch Mako's own decisions (navigation allowed or blocked, popups, page loads):

```sh
log stream --level info --predicate 'subsystem == "com.wego.mako"' --style compact
```

## Verification and performance

- `scripts/smoke`: every feature recipe in `.claude/skills/verify-mako/features/`, then `perf`. One `PASS`/`FAIL` line per check; exit status is the number of failures. Takes focus for about 3 minutes.
- `scripts/perf`: performance budgets (launch, new tab, tab switch, memory, bundle size, Rust core). See the top of the script for the numbers.
- `scripts/ab <base-checkout> <candidate-checkout> [rounds]`: paired A/B of in-app latency (launch, new tab, tab switch) between two built checkouts, interleaving launches so background load hits both alike. Prints medians, the median paired delta, and how often the candidate won. Use it to decide whether a change is faster; a single `perf` run is too noisy on a busy Mac.
- `scripts/doc-check`: fails if this page is missing a command.

## Troubleshooting

- **Exit 8, "the screen is locked".** Unlock and rerun. Locked screens hide all windows from AX.
- **Exit 8 with the screen unlocked.** Toggle the terminal off and on in Accessibility, then restart the terminal.
- **Exit 7.** Someone was typing in another app; macOS kept their focus. Rerun when the keyboard is idle.
- **Keys do nothing, menus do nothing.** A menu may be stuck open (only possible if something opened it by clicking); `$C stop` and relaunch.
- **`launch` says "already running".** `$C stop` first, or use a different `MAKO_RUN`.
