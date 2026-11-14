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
$M $P title                           # "Example Domain"
$C stop
```

## Isolation: which Mako you are driving

`control-mako` never touches the Mako you use day to day.

- Each run drives its own copy of the build, `verify-runs/<run>/app/Mako.app`, with its own bundle ID, `com.wego.mako.verify.<run>`. macOS and WebKit store cookies, logins, caches, local storage, preferences and window positions by bundle ID, so a run shares none of them with your daily Mako or with other runs. A run is never signed in to anything you are.
- The copy has no `http`/`https` URL handlers, so macOS never offers it for links you open. It is re-signed ad hoc, so it never carries the passkey entitlement even when the daily build does.
- `launch` starts the run with no website data; `stop` deletes that data (`~/Library/{WebKit,Caches,HTTPStorages,Preferences}/com.wego.mako.verify.<run>*`). Data persists across `quit` and `relaunch` within a run.
- `MAKO_CONFIG` points at `verify-runs/<run>/state/config`, so your `~/.config/mako/config` and `trails.json` are never read or written: Mako keeps `trails.json` beside whichever config it uses.
- `MAKO_DOWNLOADS` points at `verify-runs/<run>/state/downloads`, so a run's downloads never land in your Downloads folder.
- `makoctl` targets a process ID, never an app name, so it cannot reach another Mako by accident.

`scripts/isolation-ax` (part of every `smoke` run) proves this: a cookie and local storage set in one run are invisible to a second run, and your daily Mako's data files are unchanged afterwards.

`MAKO_RUN=verify-runs/<name>` keeps separate runs apart (default `verify-runs/latest`). Each run has `state/` (config, `trails.json`, downloads; deleted by `stop`), `pid`, `app/` (its copy of the build) and `evidence/` (screenshots and logs; never deleted by the tools).

## control-mako

| Command | What it does |
| --- | --- |
| `control-mako build` | Runs `script/bundle` (Rust core + Swift app) and compiles `makoctl` into `verify-runs/.bin/`. |
| `control-mako launch [config-file\|""] [url...]` | Fresh state (config, no `trails.json`, no website data), then start the run's own app copy. `""` uses the default test config (`max_trails = 3`, `block x.com`); a file path copies that config. Each URL opens as a trail, beneath the active page once the trail cap is reached. Refuses if this run already has a live instance. Prints `pid <n> ready`. |
| `control-mako pid` | Prints the running instance's pid. |
| `control-mako doctor` | Read-only health check: process alive, it is this checkout's build, AX answers, screenshots work. Prints `OK …` or `FAIL <reason>`. Run it first and after anything surprising. |
| `control-mako quit` | Presses Mako → Quit Mako, so `applicationWillTerminate` runs (it deletes `trails.json` when the config says `restore_session = false`). With `MAKO_BACKGROUND=1` it sends SIGTERM instead, which skips that hook. Waits for exit. Keeps `state/`. Mako saves `trails.json` after every change, so a quit is not needed to save. |
| `control-mako relaunch [url...]` | Starts again on the existing `state/` (config and `trails.json`), as a user reopening Mako would. Also works after the process was killed. |
| `control-mako stop` | Kills the instance this run started, deletes `state/` and the run's website data. Evidence stays. |

Exit status is 0 on success, 1 on failure, 64 on bad usage.

## makoctl

Every command is `makoctl <pid> <command> [args]`. Without `MAKO_BACKGROUND=1`, the commands that send input (`key`, `type`, `menu`, `press`, `time-key`, `click-id`, `middle-click-id`, `middle-click`, `hover`, `drag`, `double-click`) first bring Mako to the front: a background app has no key window, so keys sent to it are dropped. With `MAKO_BACKGROUND=1`, the key and pointer commands are refused (exit 9) and `menu`, `press`, `press-id`, `set` and `confirm` act through AX without focus (see [Running while the Mac is in use](#running-while-the-mac-is-in-use)). Read-only commands always work with Mako in the background.

### Reading state

| Command | Output |
| --- | --- |
| `makoctl <pid> title` | The window's AX title: the active page's label (its name, else its title, else its address), or `Mako` when no page is open. |
| `makoctl <pid> wait-title <substring> [seconds]` | Polls every 50 ms until the title contains the substring (default 10 s). Prints the title; exit 5 on timeout. The standard way to wait for a page load or a page switch. |
| `makoctl <pid> tree [depth] [--menus]` | The AX tree, one element per line: role, subrole, `id=`, `title=`, `desc=`, `value=`. Default depth 12. Web page content appears under `AXWebArea`. `--menus` includes the menu bar; a menu item with a shortcut shows its key as `cmd="1"`. |
| `makoctl <pid> value <ax-identifier>` | The `AXValue` of the element with that identifier, e.g. the omnibox text, or `1`/`0` for a checkbox. Exit 4 if absent. |
| `makoctl <pid> exists <ax-identifier>` | Exit 0 if an element with that identifier is in the tree, 4 otherwise. Hidden elements can still exist; use `shot` to prove visibility. |
| `makoctl <pid> frame <ax-identifier>` | The element's frame as `x y width height`, whole screen points from the top-left of the main display. Exit 4 if absent. Compare elements of one window, such as a sidebar row and its toggle, rather than absolute positions. |
| `makoctl <pid> text` | The active page's visible text, untruncated, one line per text run (`tree` shortens values to 80 characters). |
| `makoctl <pid> menu-items <Menu>` | One line per item in a menu bar menu; the checked item starts with `*`. `menu-items Trails` lists the visible pages with the active one checked. Does not open the menu. |
| `makoctl <pid> windows` | One line per window. Sign-in popups carry `id="mako.popup"`. |
| `makoctl <pid> pointer-center` | Moves the mouse pointer over the middle of the page. Perf runs use it so cursor-update costs are measured the same way every time. Moves the user's real pointer. |
| `makoctl <pid> shot <path.png>` | Screenshot of Mako's main window, even if other apps cover it. Exit 6 without Screen Recording permission. The only command that works without Accessibility permission. |
| `makoctl <pid> click-id <ax-identifier> [fx fy]` | Real mouse click at a point inside the element: `fx`/`fy` are fractions of its frame (default the centre). For a stepper, `0.5 0.25` hits the up arrow and `0.5 0.75` the down arrow. Activates Mako and moves the user's real pointer, so it is refused with `MAKO_BACKGROUND=1` (exit 9). |
| `makoctl <pid> middle-click-id <ax-identifier> [fx fy]` | Real middle-button click inside the element, like `click-id`: `middle-click-id mako.trail.3` closes that page. Activates Mako, moves the pointer, refused with `MAKO_BACKGROUND=1`. |
| `makoctl <pid> middle-click <x> <y>` | Real middle-button click at `x`,`y` points from the top-left of `mako.page` (CSS pixels at 100% zoom), for page content such as the `fixtures/trails/m.html` targets. Same focus rules as `click-id`. |
| `makoctl <pid> window-frame` | `x y width height` of the main window in screen points from the top-left. Read-only. |
| `makoctl <pid> hover <x> <y>` | Moves the real pointer to `x`,`y` points from the window's top-left: `hover 2 300` reaches the left edge that peeks a hidden sidebar. Same focus rules as `click-id`. |
| `makoctl <pid> drag <x> <y> <dx> <dy>` | Real left-button drag from `x`,`y` (window points) by `dx`,`dy` in ten steps: dragging the sidebar's paper or the top strip moves the window. Same focus rules as `click-id`. |
| `makoctl <pid> double-click <x> <y>` | Real left double-click at `x`,`y` (window points), as on a title bar. Same focus rules as `click-id`. |

### Acting

| Command | Effect |
| --- | --- |
| `makoctl <pid> key <combo>` | Presses a key. Modifiers `cmd`, `shift`, `opt`, `ctrl` joined with `+`. Keys: `return`, `escape`, `tab`, `a`, `c`, `f`, `g`, `l`, `r`, `t`, `v`, `w`, `x`, `z`, `[`, `]`, `0`–`9`, `=`, `-`, `,`, `.`. Examples: `cmd+t`, `cmd+opt+t`, `cmd+shift+t`, `ctrl+tab`, `cmd+f`, `cmd+shift+g`, `cmd+opt+c`, `escape`. Exit 64 for a key not in the table; add it to `keyCodes` in `makoctl.swift`. |
| `makoctl <pid> type <text>` | Types text into whatever has focus: the omnibox after `key cmd+l`, a web form field, the developer console. Any Unicode text works. |
| `makoctl <pid> menu <Menu> <Item>` | Presses a menu item by its exact titles, e.g. `menu File "New Trail"`, `menu Trails "Example Domain"`, `menu View "Developer Console"`. Does not open the menu (an open menu would swallow later keys). |
| `makoctl <pid> press-id <ax-identifier>` | Presses the element with that identifier, e.g. a sidebar row: `press-id mako.trail.3`. Works with Mako in the background. |
| `makoctl <pid> set <ax-identifier> <text>` | Sets an element's value without typing: `set mako.omnibox.field example.com`. Works in the background. |
| `makoctl <pid> confirm <ax-identifier>` | Presses Enter on a text field through AX: `confirm mako.omnibox.field` loads what the omnibox holds. Works in the background. |
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
| 8 | AX degraded: the screen is locked, or with the screen unlocked, the terminal's Accessibility grant went stale. Every command but `shot` checks for this first. |
| 9 | The command needs focus and `MAKO_BACKGROUND=1` is set (`key`, `type`, `time-key`, `click-id`, `middle-click-id`, `middle-click`, `hover`, `drag`, `double-click`). |
| 64 | Bad usage or unknown key. |

## AX handles

Stable identifiers Mako sets for automation. Prefer these, menu titles, and the window title over tree position or coordinates.

| Identifier | Element |
| --- | --- |
| `mako.page` | Container for the active page's web view. |
| `mako.sidebar` | The trails sidebar. |
| `mako.trail.<id>` | A sidebar row (a page). `id` is the page's permanent id, not a position. Its AX value is `selected` on the active page; its AX help is `site icon` once the site's icon has arrived, `no site icon` before. |
| `mako.sidebar.load` | The note at the sidebar's foot, present only at the trail cap. Value `🧠 <open>/<max>`. Redrawn on any saved config edit too, so a cap changed in Settings or the file shows at once. |
| `mako.sidebar.config` | The note above it, present only while the config has unusable lines. Value ``⚠ config line <n>: <problem>: `<line>` ``, plus ` (and <k> more)` when there are several. Clicking or pressing it opens the config file in the default editor, like ⌘,, and that editor takes focus: never press it in a background run. Mako watches the config file and its folder, so the note appears or goes within a moment of any saved edit, with no other action. |
| `mako.trail.<id>.toggle` | That row's collapse/expand control (only when it has pages beneath it). |
| `mako.trail.<id>.name` | The text field that replaces a row's label while it is being renamed (Trails → Rename Page…). `set` it, then `confirm` it. |
| `mako.divider` | The edge between sidebar and page. Its value is the sidebar width in points; `set mako.divider 300` resizes it (kept between 160 and the smaller of 480 and the window width less 400). |
| `mako.settings.maxTrails` | Settings window (⌘., or `menu Mako "Settings…"`) trail-cap field. `set` then `confirm` saves 1–9 to the config as `max_trails = N`; anything else is refused and the saved value shown again. `.stepper` is the stepper beside it. |
| `mako.trail.<id>.page` | A loaded page's web view. Only recently shown pages are loaded. |
| `mako.omnibox` | The address bar panel; absent from the tree while hidden. |
| `mako.omnibox.field` | Its text field; `value` is the text in it. |
| `mako.omnibox.status` | The lines under the field: errors, what Enter will do, and the trail and page counts. |
| `mako.blank` | The app icon shown when no page is open. |
| `mako.popup` | A sign-in popup window. |
| `mako.dialog.ok`, `mako.dialog.cancel` | A page dialog's buttons (Cancel only for `confirm()` and `prompt()`). |
| `mako.dialog.field` | A `prompt()` dialog's text field. |
| `mako.dialog.silence` | The "Don’t show more dialogs from this page" checkbox, from a page's second dialog on; value `1` when ticked. |

Menu bar: `Mako` (About Mako, Settings… ⌘., Edit Config File… ⌘,, Hide Mako, Quit Mako), `File` (New Trail ⌘T, New Page in Trail ⌥⌘T, Open Location… ⌘L, Close Page ⌘W, Reopen Closed Page ⇧⌘T), `Edit` (Undo, Redo, Cut, Copy, Paste, Select All, Find… ⌘F, Find Next ⌘G, Find Previous ⇧⌘G), `View` (Reload ⌘R, Zoom In ⌘=, Zoom Out ⌘-, Actual Size ⌘0, Developer Console ⌥⌘C, Enter Full Screen), `History` (Back ⌘[, Forward ⌘]), `Trails` (Next Page, Previous Page, Move Page Up, Move Page Down, Indent Page, Outdent Page, Rename Page…, then one item per visible page, indented by depth, the active one checked). A trail's root item carries ⌘1…⌘9 and jumps: to the root, or from the root to the trail's last page. So `menu Trails "<root label>"` pressed while that root is active goes to the last page.

## Recipes

Open a URL in the current page:

```sh
$M $P key cmd+l; $M $P type "https://example.com"; $M $P key return
$M $P wait-title "Example Domain"
# background equivalent:
$M $P menu File "Open Location…"; $M $P set mako.omnibox.field https://example.com; $M $P confirm mako.omnibox.field
```

Start a new trail (⌘T), or open a page beneath the current one (⌥⌘T):

```sh
$M $P key cmd+t; $M $P type "news.ycombinator.com"; $M $P key return
$M $P wait-title "Hacker News"
# background equivalent:
$M $P menu File "New Trail"; $M $P set mako.omnibox.field news.ycombinator.com; $M $P confirm mako.omnibox.field
```

List pages and switch to one:

```sh
$M $P menu-items Trails
$M $P menu Trails "Hacker News"     # or: $M $P press-id mako.trail.3
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

Run JavaScript in the page and read the result through the title (needs focus: typing into the console):

```sh
$M $P key cmd+opt+c                     # developer console; focus is in its prompt
$M $P type 'document.title = String(document.links.length)'; $M $P key return
$M $P title
```

Test a restore (`trails.json` is current after every change, so a kill restores as well as a quit):

```sh
cat verify-runs/latest/state/trails.json; $C quit; $C relaunch; P=$($C pid)
```

Watch Mako's own decisions (navigation allowed or blocked, popups, page loads):

```sh
log stream --level info --predicate 'subsystem == "com.wego.mako"' --style compact
```

Move, rename and find, all in the background:

```sh
$M $P menu Trails "Indent Page"        # active page goes under the page above it; Outdent, Move Page Up/Down likewise
$M $P menu Trails "Rename Page…"; $M $P set mako.trail.6.name "Mine"; $M $P confirm mako.trail.6.name
$M $P menu Edit "Find…"; $M $P set mako.omnibox.field needle; $M $P confirm mako.omnibox.field
$M $P value mako.omnibox.status         # first line is "Not found" on a miss
```

Dragging a row onto another (before, after or inside it) has no AX equivalent; the menu moves reach the same core actions.

## Running while the Mac is in use

Set `MAKO_BACKGROUND=1` for both tools. `control-mako launch` then starts the test copy behind every other window and Mako never activates itself; `makoctl` refuses `key`, `type`, `time-key`, `click-id`, `middle-click-id`, `middle-click`, `hover`, `drag` and `double-click` with exit 9 (they need focus or move the pointer) and everything else works through AX: `menu`, `press`, `press-id`, `set`, `confirm`, and all the read commands. Mako's own menu items name the browser (or Settings) as their target, so they work while it is in the background; `control-mako quit` sends SIGTERM rather than pressing Quit Mako.

`scripts/trails-bg` goes further and needs no permissions at all: fixture pages click their own links and the script reads the saved `trails.json` and Mako's log.

## Trails state on disk

`trails.json` sits beside the config (`verify-runs/<run>/state/trails.json` for test runs). It is the core's whole state: `roots`, `nodes` (each with `parent`, `children`, `url`, `title`, `name`, `collapsed`), `active`, `closed` (the Undo Close stack, up to 20), `colors` (each trail's colour slot, keyed by root id), `next_id` and `version`. It is rewritten after every change (never with `restore_session = false`), so reading it is the most direct way to assert the tree. A file Mako cannot read is moved aside to `trails.json.bad` and Mako starts empty; with no `trails.json`, a tabs-era `session.json` beside the config is migrated once.

## Verification and performance

Every script prints one `PASS`/`FAIL` line per check and exits with the number of failures (99 when it could not build or launch). The check scripts build first unless `MAKO_SKIP_BUILD=1`; `perf` and `ab` use the existing build.

- `scripts/trails-bg`: trails behaviour (links nest, restart restore, lazy loading, trail cap, blocked links under a config with unusable lines, form submits, trail colours, site icons, file links) with no focus and no permissions. 25 checks.
- `scripts/trails-ax`: the trails UI through accessibility actions, no focus: sidebar rows, collapse, ⌘1…⌘9 jumps through the Trails menu, sidebar width, Settings, omnibox, trail cap and the 🧠 note, close, Undo Close across a restart, moving and renaming pages, find in page, deep rows at the narrowest sidebar, live config edits redrawing the sidebar's notes. 59 checks. Needs Accessibility permission.
- `scripts/dialogs-bg`: `alert()`, `confirm()` and `prompt()` wait for the person, read from `trails.json`; no focus, no permissions. 3 checks.
- `scripts/dialogs-ax`: page dialogs through accessibility actions, no focus: silencing with the dialog checkbox, lifted only by a navigation the person starts from Mako (address bar, Back, Forward, Reload), never by the page reloading itself or a same-document Back. 17 checks. Needs Accessibility permission.
- `scripts/isolation-ax`: a run's cookies and local storage are invisible to a second run, and the daily Mako's data files are unchanged (`SKIP` while the daily Mako runs). 4 checks. Needs Accessibility permission, no focus.
- `scripts/ux-headed`: middle-clicks on page content (`fixtures/trails/m.html`, a `target=_blank` link and a download link included) and sidebar rows, ⌘1 as a key, the omnibox with a long address, which icon each row shows. 24 checks. Takes the pointer and keyboard; needs Accessibility and Screen Recording.
- `scripts/settings-headed`: the Settings window with a real ⌘., stepper clicks, typed values and ⌘W. 12 checks. Takes the pointer and keyboard; needs Accessibility and Screen Recording.
- `scripts/smoke`: the full pass. Runs `doc-check`, builds once, runs `trails-bg`, `trails-ax`, `dialogs-bg`, `dialogs-ax` and `isolation-ax`, then `ux-headed` and `settings-headed` only with `SMOKE_HEADED=1`, then `perf` (in background mode unless `SMOKE_HEADED=1`). Ends with a `SUMMARY` line per script; exit status is the total number of failures.
- `scripts/perf`: performance budgets (launch to interactive, launch to first page, ⌘T New Trail, ⌘1 jump, memory with 3 trails, bundle size, Rust core). With `MAKO_BACKGROUND=1` it takes no focus and skips the ⌘T and ⌘1 budgets, which time real key presses. See the top of the script for the numbers.
- `scripts/ab <base-checkout> <candidate-checkout> [rounds]`: paired A/B of in-app latency (launch, ⌘T New Trail, ⌘1 jump) between two built trails checkouts, interleaving launches so background load hits both alike. Prints medians, the median paired delta, and how often the candidate won. Use it to decide whether a change is faster; a single `perf` run is too noisy on a busy Mac. Takes the keyboard.
- `scripts/doc-check`: fails if this page is missing a command.

## Troubleshooting

- **Exit 8, "the screen is locked".** Unlock and rerun. Locked screens hide all windows from AX.
- **Exit 8 with the screen unlocked.** Toggle the terminal off and on in Accessibility, then restart the terminal.
- **Exit 7.** Someone was typing in another app; macOS kept their focus. Rerun when the keyboard is idle.
- **Keys do nothing, menus do nothing.** A menu may be stuck open (only possible if something opened it by clicking); `$C stop` and relaunch.
- **`launch` says "already running".** `$C stop` first, or use a different `MAKO_RUN`.
