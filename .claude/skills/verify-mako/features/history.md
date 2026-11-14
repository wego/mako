# History

Mako remembers the web pages it finishes loading in `history.json` beside the config: one entry per address with its title, how often it was visited and when last. The address bar suggests from it as you type (`features/omnibox.md`, `omni-suggest`). Nothing in it leaves the Mac. `remember_history = false` turns it off, and History → Clear History… forgets everything.

## Sub-features

- `hist-record` a page that finishes loading in a trail is recorded: `{url, title, visits, last_visit}` (unix seconds), the `#fragment` dropped. A repeat visit adds 1 to `visits`, moves `last_visit` and takes the newer title. Only `http` and `https` pages count: never `data:`, `file:` or `about:` pages, a sign-in popup, a block or error notice, nor a host the blocklist blocks at that moment.
- `hist-once` a page loading the address it already had (ignoring its `#fragment`) is no visit: a reload, an in-page jump then a reload, a page restored at launch, a page loaded again after Mako unloaded it. So a relaunch leaves every count as it was.
- `hist-title` a title that arrives or changes after the load updates the entry without a visit.
- `hist-cap` at 5,000 entries a new address replaces the entry with the lowest score, `(1 + ln visits) × 0.5^(age ÷ 30 days)`.
- `hist-off` `remember_history = false` (default `true`) records nothing, not even a later title for an address already in it, and suggests nothing from history; open pages are still suggested. The file is left as it was, so turning history on again brings its suggestions back. Any other value is a config issue (`mako.sidebar.config`) and history stays on.
- `hist-clear` History → Clear History… asks on a sheet (`mako.dialog.ok` Clear History, `mako.dialog.cancel` Cancel). Cancel changes nothing; Clear History empties `history.json` (`"entries":[]`) and the suggestions with it. Open pages and trails stay.
- `hist-bad-file` a `history.json` Mako cannot read is moved to `history.json.bad` and history starts empty (from source; not driven).

## How to get to it (user POV)

- Browse: every page load is recorded.
- Type in the address bar (⌘L, ⌘T, ⌥⌘T) to see history rows.
- History → Clear History….
- Add `remember_history = false` to the config (⌘,).

## Driving it with makoctl

Preconditions: baseline; `MAKO_BACKGROUND=1` is fine for every step. Serve the still pages: `python3 -m http.server $PORT --bind 127.0.0.1 -d .claude/skills/verify-mako/fixtures/omnibox &`, `U=http://127.0.0.1:$PORT`, and `$C launch "" "$U/one.html"`. `H=verify-runs/latest/state/history.json`. `scripts/omnibox-ax` runs all of this.

- **Record.** `cat $H` holds one entry: `one.html`, title `Page one`, `visits` 1. `menu File "Open Location…"; set mako.omnibox.field "$U/two.html"; confirm mako.omnibox.field`: a second entry.
- **Repeat.** Load `$U/one.html` the same way: its `visits` is 2 and `last_visit` moved.
- **Relaunch.** `$C quit; $C relaunch; P=$($C pid)`, wait for the title: `$H` is unchanged, counts included.
- **Off.** `printf 'max_trails = 3\nremember_history = false\n' > verify-runs/latest/state/config`, load `$U/five.html`: no `five.html` in `$H`. `set mako.omnibox.field page` lists only `Open page` rows. Write the config back without the line: history rows return.
- **Clear.** `menu History "Clear History…"`: `exists mako.dialog.cancel` exits 0; `press-id mako.dialog.cancel` leaves `$H` alone. Again, then `press-id mako.dialog.ok`: `$H` is `{"version":1,"entries":[]}` and a query that matched history lists nothing.
- **Proof.** `cp $H $E/history.json` after each step; `shot $E/clear-history.png` with the sheet up.

## Gotchas

- Visits are recorded when a load finishes, so read `$H` after `wait-title`, not right after `confirm`.
- A page that changes its address without loading (a single-page app's `pushState`) is not recorded.
- `$C quit` under `MAKO_BACKGROUND=1` is a SIGTERM; the history is saved on every change, so nothing is lost.
- The core's ranking and pruning rules are covered by `cargo test --manifest-path core/Cargo.toml` (`history::tests`); `cargo test --release --manifest-path core/Cargo.toml -- --ignored perf_budget_suggest` times a 5,000-entry suggest (budget 5 ms).
