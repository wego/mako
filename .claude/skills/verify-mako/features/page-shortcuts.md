# Page shortcuts

Mako's own shortcuts (⌘T ⌘W ⌘L ⌘, ⌘1–9 ⌥⌘C) always reach Mako, even when a page has focus. The match is exact: ⌘⇧T or ⌘⇧1 go to the page first. Every other ⌘ key (⌘Z, ⌘C, ⌘V, ⌘R, ⌘[, ⌘]) goes to the web page first, so web apps such as Google Docs keep their own undo.

## Sub-features

- `keys-mako` Mako shortcuts work while a page has focus.
- `keys-page` a page that handles ⌘Z receives it and Mako's menu does not act.

## How to get to it (user POV)

- Press the shortcut with focus in a web page or web editor.

## Driving it with makoctl

Preconditions: launch with a probe page that claims every ⌘ key:

```sh
PROBE="data:text/html,<title>probe</title><script>addEventListener('keydown',e=>{if(e.metaKey){e.preventDefault();document.title='got '+e.key}})</script><body contenteditable>edit</body>"
$C launch "" "$PROBE"
```

- **Page receives ⌘Z.** `$M $P key cmd+z`. `wait-title "got z"`.
- **Page receives ⌘R.** `$M $P key cmd+r`. `wait-title "got r"` (page handled it; no reload).
- **Mako keeps ⌘T.** `$M $P key cmd+t`. Title ends `– 2/2` even though the page calls `preventDefault` on every ⌘ key.
- **Proof.** `title` output after each step to `$E/keys.txt`.

## Gotchas

- Without a page that calls `preventDefault`, ⌘R reloads via Mako's menu after the page passes on it; that is the expected fallback.
