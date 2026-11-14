# Sign-in popups

"Continue with Google" style sign-ins open the provider in a popup that reports back to the page that opened it (`window.opener`). Mako gives a script-opened window a real popup window (sized by the `window.open` features, else 520×680) so that hand-back works; the popup closes when the provider calls `window.close()`, ⌘W closes it too, and the main window gets focus back. Popups live outside the trails: no sidebar row, never counted toward the trail cap, never saved. Links followed inside a popup stay in it. A clicked `target=_blank` link is not a popup but a followed link: it opens a child page beneath its page and selects it. A middle-click on something that calls `window.open` opens the address as a background child page instead of a popup.

## Sub-features

- `popup-open` a script `window.open` (with or without size features) opens a separate window, AX id `mako.popup`, logged as `popup <url>`. With `MAKO_BACKGROUND=1` it opens behind other windows.
- `popup-opener` the popup can `postMessage` to `window.opener`; the opener page receives it.
- `popup-close` `window.close()` in the popup, or ⌘W while it is in front, closes only the popup.
- `popup-dialogs` `alert()`, `confirm()` and `prompt()` from a popup show on the popup window (`features/dialogs.md`).
- `blank-link-child` a clicked `target=_blank` link opens a child page beneath its page and selects it; no window opens.
- `popup-middle-click` a middle-click on a control that calls `window.open` opens a background child page and no popup (`ux-headed` checks it).
- `safari-ua` the user agent ends with `Version/<installed Safari's version> Safari/605.1.15` (`Version/26.0` when Safari is not found), the token Google sign-in expects.

## How to get to it (user POV)

- Click "Continue with Google" (or Apple, GitHub, Microsoft) on a site's login page.
- Click a link that would open a new window.

## Driving it with makoctl

Preconditions: baseline; `MAKO_BACKGROUND=1` is fine for every step. Serve the fixtures: `python3 -m http.server $PORT --bind 127.0.0.1 -d .claude/skills/verify-mako/fixtures &`, `U=http://127.0.0.1:$PORT`.

- **Load opener.** `$C launch "" "$U/oauth-opener.html"`. `wait-title "opener"`.
- **Sign in.** `$M $P press "Continue with Provider"`. Within ~1 s `$M $P windows` lists a second window with `id="mako.popup"` and the log has `popup $U/oauth-popup.html`; then the popup closes, `wait-title "signed in"` succeeds, `windows` lists one window, and `trails.json` still holds one page.
- **Plain link.** `$M $P press "plain target=_blank link"`. `wait-title "provider"`; `trails.json` holds a second page, beneath page 1, at `oauth-popup.html?plain`, active; `windows` lists no popup.
- **Proof.** `windows` output during and after the sign-in, plus the titles and `trails.json`, into `$E/popups.txt`; the `popup` lines in the `com.wego.mako` log.

**User agent.** Serve a page that titles itself with the request's user agent, load it, and read the title, which ends with `Version/… Safari/605.1.15`:

```sh
python3 - "$UA_PORT" <<'PY' &
import http.server as h, sys
class H(h.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers()
        self.wfile.write(f"<title>{self.headers['User-Agent']}</title>".encode())
    def log_message(self, *a): pass
h.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
$M $P menu File "Open Location…"; $M $P set mako.omnibox.field "127.0.0.1:$UA_PORT"; $M $P confirm mako.omnibox.field
$M $P wait-title "Safari/605.1.15"
```

## Gotchas

- Popups and `window.opener` need a real origin; `data:` pages will not do. Use the local server.
- WebKit blocks `window.open` without a user gesture; drive the button with `press`, not by calling `window.open` from the console.
- The fixture popup closes itself after 500 ms, so ⌘W on a popup and `popup-dialogs` have no fixture and no recipe yet.
- Real providers (Google, Notion) need the user's credentials; drive only up to the provider's sign-in page and never type credentials.
- Passkeys are a separate gate: WebAuthn in a WKWebView app needs Apple's `com.apple.developer.web-browser.public-key-credential` entitlement. Without it, a site's passkey prompt fails and the user must pick password sign-in. A run's app copy is re-signed ad hoc, so it never has the entitlement; `fixtures/passkey.html` titles itself with what the passkey request returned.
