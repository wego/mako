# Page shortcuts

Mako's own shortcuts always reach Mako, even when a page has focus and claims the key: ⌘T, ⌥⌘T, ⇧⌘T, ⌘W, ⌘L, ⌘,, ⌘., ⌥⌘C, ⌘1–⌘9, and ⌃Tab / ⌃⇧Tab. The match is exact: ⌘⇧1 or ⌃⌘T is not Mako's and goes to the page first. Every other ⌘ key (⌘Z, ⌘C, ⌘V, ⌘R, ⌘F, ⌘G, ⌘[, ⌘], ⌘=, ⌘-, ⌘0) goes to the web page first and reaches Mako's menu only if the page lets it pass, so web apps such as Google Docs keep their own undo and find.

## Sub-features

- `keys-mako` Mako's shortcuts work while a page has focus, even one that calls `preventDefault` on every ⌘ key.
- `keys-page` a page that handles ⌘Z, ⌘R or ⌘F receives it and Mako's menu does not act.

## How to get to it (user POV)

- Press the shortcut with focus in a web page or web editor.

## Driving it with makoctl

Every step needs focus (real key presses), so run it headed. Launch with a probe page that claims every ⌘ key and titles itself with the key it got:

```sh
PROBE="data:text/html,<title>probe</title><script>addEventListener('keydown',e=>{if(e.metaKey){e.preventDefault();document.title='got '+e.key}})</script><body contenteditable>edit</body>"
$C launch "" "$PROBE"
```

- **Page receives ⌘Z.** `$M $P key cmd+z`. `wait-title "got z"`.
- **Page receives ⌘R.** `$M $P key cmd+r`. `wait-title "got r"` (the page handled it; no reload).
- **Page receives ⌘F.** `$M $P key cmd+f`. `wait-title "got f"`; `exists mako.omnibox` exits 4.
- **Mako keeps ⌘T.** `$M $P key cmd+t`. `$M $P tree | grep mako.omnibox.field` shows `desc="New trail`, and `title` is still `got f`, not `got t`. `key escape`.
- **Mako keeps ⌘L and ⇧⌘T.** `key cmd+l`: the field's `desc` starts `This page`; `key escape`. `key cmd+shift+t` (nothing to reopen, so Mako beeps): `title` is unchanged.
- **Proof.** `title` and `tree | grep mako.omnibox` after each step to `$E/keys.txt`.

## Gotchas

- Without a page that calls `preventDefault`, ⌘R reloads through Mako's menu after the page passes on it; that is the expected fallback.
- No script covers this file; it needs the keyboard.
