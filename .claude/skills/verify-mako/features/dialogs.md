# Page dialogs

A page's `alert()`, `confirm()` and `prompt()` show as a sheet on the window holding the page (the main window, or a sign-in popup) and the page waits for the person's answer. The sheet's bold line is the site (with its port, "This page" when there is none, and "(embedded in this page)" for a frame), so page text cannot pose as another site; the page's message sits beneath it. From a page's second dialog on, a "Don’t show more dialogs from this page" checkbox appears; once ticked, that page's dialogs are answered as if dismissed, so a page looping on `alert()` cannot lock the window. OK is the default button (Return); confirm and prompt add Cancel (Escape). A page in a trail that is not shown has no window, so its dialogs are answered as if dismissed (alert closes, confirm is false, prompt is null) and logged as `dialog from <host> dismissed`.

## Sub-features

- `dialog-alert` `alert()` shows OK and the page resumes when it is pressed.
- `dialog-confirm` `confirm()` returns true for OK, false for Cancel.
- `dialog-prompt` `prompt()` shows a field pre-filled with the default text and focused; OK returns its text, Cancel returns null.
- `dialog-popup` a dialog from a sign-in popup shows on the popup window.
- `dialog-hidden-page` a dialog from a page not shown is dismissed and logged, never brought to the front.

## How to get to it (user POV)

- Any page that calls the functions, e.g. GitHub's "Uninstall" for a GitHub App asks `confirm()`.

## Driving it with makoctl

Fixture pages in `fixtures/dialogs/` open a dialog 300 ms after load and set their title to the answer (`alert:done`, `confirm:true`, `prompt:<text>`); until then it is `waiting`. Serve them with `python3 -m http.server $PORT --bind 127.0.0.1 -d .claude/skills/verify-mako/fixtures/dialogs &`.

- **No permissions, no focus.** `.claude/skills/verify-mako/scripts/dialogs-bg` launches each fixture and checks the title is still `waiting` 4 s later, from `trails.json`. 3 checks. It proves the dialog waits; it does not answer it.
- **Answering (AX).** Launch on `$U/confirm.html`. `$M $P exists mako.dialog.ok`, then `$M $P press-id mako.dialog.ok`; `title` becomes `confirm:true`. `press-id mako.dialog.cancel` gives `confirm:false`. For prompt, `set mako.dialog.field hello` then `press-id mako.dialog.ok`; `title` is `prompt:hello`.
- **Proof.** `title` before and after the press, plus a `shot` of the sheet.

## Gotchas

- Answering needs Accessibility permission or a person; without it `makoctl` exits 2 with `accessibility permission missing for this terminal`.
- `mako.dialog.ok`, `mako.dialog.cancel` and `mako.dialog.field` were set on the NSAlert's buttons and field but have not yet been read back through AX in a run.
- A second dialog while a sheet is up should queue behind it (AppKit queues sheets); not yet seen in a run.
- `dialog-popup` and `dialog-hidden-page` are not covered by a script.
