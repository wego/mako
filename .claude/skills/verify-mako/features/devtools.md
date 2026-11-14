# Developer console

⌥⌘C (View → Developer Console) toggles WebKit's Web Inspector for the shown page, docked at the bottom on the Console tab. The same key closes it, even while focus is inside the inspector. With no page shown it beeps. Every page is also inspectable from Safari's Develop menu.

## Sub-features

- `devtools-open` ⌥⌘C or the menu opens the inspector on the Console tab.
- `devtools-eval` the console evaluates JavaScript in the page; a `document.title` change there renames the page's row and the window.
- `devtools-close` ⌥⌘C or the menu again closes it, including with focus in the console.
- `devtools-safari` each page's web view is inspectable (`isInspectable`), so Safari → Develop lists Mako's pages.

## How to get to it (user POV)

- Press ⌥⌘C.
- Choose View → Developer Console.
- Right-click a page → Inspect Element.
- Safari → Develop → this Mac → the page.

## Driving it with makoctl

Preconditions: baseline launched with `https://example.com`.

- **Open.** `$M $P menu View "Developer Console"`, then poll `for i in $(seq 10); do [ "$($M $P tree 12 | grep -c AXWebArea)" -ge 2 ] && break; sleep 1; done`: `tree 12 | grep -c AXWebArea` reaches at least 2 (page and inspector). With Mako in the background the inspector appears after 2 s on a fresh launch and has taken over 5 s after other actions, so poll rather than sleep (page and inspector); `shot $E/console-open.png` shows the Console tab. Works with `MAKO_BACKGROUND=1`.
- **Evaluate (focus).** `$M $P key cmd+opt+c` opens it with focus in the console prompt. `$M $P type 'document.title="from console"'; $M $P key return`. `wait-title "from console"` succeeds.
- **Close.** `$M $P menu View "Developer Console"; sleep 4`, or **(focus)** `key cmd+opt+c` with focus still in the console. `tree 12 | grep -c AXWebArea` prints 1; `shot` shows no inspector.
- **No page.** `$C stop; $C launch` (no address, so no page): `menu View "Developer Console"` adds no `AXWebArea` (it beeps, which a run cannot observe).

## Gotchas

- Right after the first open, WebKit briefly adds a small `AXDialog` window and can leave a stray button on screen for a few seconds after closing. Wait ~4 s before asserting the closed state.
- Docked position, Inspect Element in the context menu, and console focus are WebKit defaults. If someone detaches the inspector, WebKit remembers that and later opens show a separate window, so check `windows` for a second window as well as a second `AXWebArea`.
- The inspector uses private WebKit API (`_inspector`) plus the `developerExtrasEnabled` preference; a WebKit update that removes either makes ⌥⌘C beep. This recipe catches that.
- The inspector belongs to one page's web view. What it does when another page is selected while it is open has not been observed in a run.
