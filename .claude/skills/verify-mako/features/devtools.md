# Developer console

⌥⌘C (View → Developer Console) toggles WebKit's Web Inspector for the active tab, docked at the bottom on the Console tab. The same key closes it, even while focus is inside the inspector.

## Sub-features

- `devtools-open` ⌥⌘C or the menu opens the inspector on the Console tab.
- `devtools-eval` the console evaluates JavaScript in the page.
- `devtools-close` ⌥⌘C again closes it, including with focus in the console.

## How to get to it (user POV)

- Press ⌥⌘C.
- Choose View → Developer Console.
- Right-click a page → Inspect Element.

## Driving it with makoctl

Preconditions: baseline launched with `https://example.com`.

- **Open.** `$M $P key cmd+opt+c; sleep 2.5`. `$M $P tree 12 | grep -c AXWebArea` prints 2 (page + inspector); `shot $E/console-open.png` shows the Console tab.
- **Evaluate.** Focus is in the console prompt after opening. `$M $P type 'document.title="from console"'; $M $P key return`. `wait-title "from console"` succeeds.
- **Close.** `$M $P key cmd+opt+c; sleep 4`. `tree 12 | grep -c AXWebArea` prints 1; `shot` shows no inspector.
- **Menu.** `$M $P menu View "Developer Console"` toggles the same way.

## Gotchas

- Right after the first open, WebKit briefly adds a small `AXDialog` window and can leave a stray button on screen for a few seconds after closing. Wait ~4 s before asserting the closed state.
- Docked position, Inspect Element in the context menu, and console focus are WebKit defaults. If someone detaches the inspector, WebKit remembers that and later opens show a separate window, so check `tree 1` for a second `AXWindow` as well as a second `AXWebArea`.
- The inspector uses private WebKit API (`_inspector`) plus the `developerExtrasEnabled` preference; a WebKit update that removes either makes ⌥⌘C beep. This recipe catches that.
