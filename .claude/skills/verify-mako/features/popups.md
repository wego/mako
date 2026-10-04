# Sign-in popups

"Continue with Google" style sign-ins open the provider in a popup that reports back to the page that opened it (`window.opener`). Mako gives script-opened windows a real popup window so that hand-back works; the popup closes itself when the provider is done. Clicked `target=_blank` links still load in the current tab, and popups never count toward the tab cap.

## Sub-features

- `popup-open` a script `window.open` (with or without size features) opens a separate popup window, AX id `mako.popup`.
- `popup-opener` the popup can `postMessage` to `window.opener`; the opener page receives it.
- `popup-close` `window.close()` in the popup closes its window.
- `blank-link-same-tab` a clicked `target=_blank` link replaces the current tab instead of opening anything.
- `safari-ua` the user agent ends with Safari's `Version/<installed Safari> Safari/605.1.15` token, which Google sign-in expects.

## How to get to it (user POV)

- Click "Continue with Google" (or Apple, GitHub, Microsoft) on a site's login page.
- Click a link that would normally open a new tab.

## Driving it with makoctl

Preconditions: baseline launched with any page. Serve the fixtures: `python3 -m http.server $PORT --bind 127.0.0.1 -d .claude/skills/verify-mako/fixtures &`.

- **Load opener.** `$M $P key cmd+l; $M $P type "http://127.0.0.1:$PORT/oauth-opener.html"; $M $P key return`. `wait-title "opener"`.
- **Sign in.** `$M $P press "Continue with Provider"`. Within ~1 s `$M $P windows` lists a second window with `id="mako.popup"`, then it closes, and `wait-title "signed in – 1/1"` succeeds.
- **Plain link.** `$M $P press "plain target=_blank link"`. `wait-title "provider – 1/1"`: same tab, no popup.
- **User agent.** In the console (⌥⌘C) run `navigator.userAgent`; it ends with `Version/… Safari/605.1.15`.
- **Proof.** `windows` output during and after the sign-in, plus the titles, into `$E/popups.txt`; the `popup` lines in the `com.chuyeow.mako` log.

## Gotchas

- Popups and `window.opener` need a real origin; `data:` pages will not do. Use the local server.
- WebKit blocks `window.open` without a user gesture; drive the button with `press`, not by calling `window.open` from the console.
- Real providers (Google, Notion) need the user's credentials; drive only up to the provider's sign-in page and never type credentials.
- Passkeys are a separate gate: WebAuthn in a WKWebView app needs Apple's `com.apple.developer.web-browser.public-key-credential` entitlement. Without it, a site's passkey prompt fails and the user must pick password sign-in.
