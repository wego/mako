# Settings

⌘. (Mako → Settings…) opens a small Settings window with one setting, the trail cap: "Maximum trails:", a field and a stepper beside it, from 1 to 9. A whole number in that range, typed and confirmed with Enter, or a click on a stepper arrow, is saved at once to the config as `max_trails = N`, rewriting only that line (or appending it) and keeping comments, block rules and everything else as written. Anything else typed is refused: the field shows the saved value again. Lowering the cap never closes a trail; it stops new ones until enough close. A note says pages within a trail are unlimited, and "Open Config File…" opens the config in the default editor, like ⌘,. ⌘W closes Settings and nothing else. A `max_trails` above 9 written in the config file itself is clamped to 9, one trail per sidebar colour.

## Sub-features

- `settings-open` ⌘. or Mako → Settings… opens the window, showing the cap in force (3 by default). With `MAKO_BACKGROUND=1` it opens behind other windows without taking focus.
- `settings-field` a typed 1–9 confirmed with Enter is saved; 0, 10 and up, and anything not a whole number are refused and the saved value shown again.
- `settings-stepper` each arrow click moves the cap by one within 1–9 and saves it.
- `settings-one-line` saving rewrites only the `max_trails` line, or appends one; every other line stays as written.
- `settings-lower` lowering the cap below the open trails closes none; new trails are refused (`Can’t open: trail cap reached (N)`) and the sidebar's foot shows `🧠 <open>/<max>` from the next change on.
- `settings-close` ⌘W with Settings in front closes it and leaves the trails alone.
- `settings-config-button` "Open Config File…" opens the config in the default editor.

## How to get to it (user POV)

- Press ⌘. or choose Mako → Settings….

## Driving it with makoctl

Preconditions: baseline; `MAKO_BACKGROUND=1` is fine except where marked. `CF=verify-runs/latest/state/config`.

- **No focus.** `.claude/skills/verify-mako/scripts/trails-ax` covers `settings-open` (in the background), `settings-field` (refuses 0, saves 2) and `settings-one-line`. 6 of its checks.
- **Headed.** `.claude/skills/verify-mako/scripts/settings-headed` covers a real ⌘., the stepper arrows (up to 4, down to 2, stops at 1), a typed 7, a refused 12, the `block` line kept, and ⌘W closing only Settings. 12 checks.
- **Open.** `$M $P menu Mako "Settings…"`. `value mako.settings.maxTrails` is `3`; `windows` lists a `Settings` window.
- **Refuse.** `set mako.settings.maxTrails 10; confirm mako.settings.maxTrails`: the value is `3` again and `$CF` still says `max_trails = 3`. The same for `0` and `two`.
- **Save.** `set mako.settings.maxTrails 2; confirm mako.settings.maxTrails`: `grep -x 'max_trails = 2' $CF` matches, `grep -x 'block x.com' $CF` still matches, and no other line changed (`diff` against a copy taken first).
- **Lower below the open trails.** `$C stop`, serve the trail fixtures (`fixture-server $PORT &`, `U=http://127.0.0.1:$PORT`) and `$C launch "" "$U/c.html" "$U/c.html?2" "$U/c.html?3"`: three trails. In Settings, `set` 1 and `confirm`. `trails.json` still has three roots. `menu File "New Trail"`, `set mako.omnibox.field "$U/h.html"`, `confirm mako.omnibox.field`: `value mako.omnibox.status | head -1` says `trail cap reached (1)`. `press-id mako.trail.1`, then `value mako.sidebar.load` is `🧠 3/1`.
- **Clamp in the file.** `sed -i '' 's/^max_trails = .*/max_trails = 12/' $CF`, then `menu Mako "Settings…"` again: `value mako.settings.maxTrails` is `9`.
- **Close (focus).** `key cmd+w` with Settings in front: `windows` no longer lists it and `exists mako.sidebar` exits 0.
- **Proof.** The config before and after each save, `value` after each step, `shot` with Settings in front.

## Gotchas

- The stepper arrows need real clicks (`click-id mako.settings.maxTrails.stepper 0.5 0.25` for up, `0.5 0.75` for down), so they are headed only.
- Never press "Open Config File…" in a run: it opens the config in the person's editor.
- The field refuses out-of-range input; only the config file clamps.
- The 🧠 note is redrawn on the next change to the trails, not when Settings saves (from source), so it reads `🧠 3/3` until a page is selected, opened or closed.
- `shot` captures the run's frontmost window, which is Settings only while Settings is in front.
