# Mako

A minimal macOS browser for focus: two trails instead of tabs, and a blocklist. A trail is a tree of pages: every link you follow opens beneath the page it came from, in a sidebar, so you always see how you got somewhere.
Swift/AppKit shell over WKWebView; policy and omnibox logic in a small Rust core.

## Build

    script/bundle          # -> build/Mako.app (Rust core + Swift shell, ad-hoc signed)
    open build/Mako.app
    cargo test --manifest-path core/Cargo.toml

## Keys

| Key | Action |
| --- | --- |
| ⌘T | New trail (refused at the cap; default 3, set in Settings) |
| ⌥⌘T | New page beneath the current one |
| ⌘L | Omnibox: load an address in the current page (one line; long addresses shrink to fit) |
| ⌘W / ⇧⌘T | Close page (with the pages beneath it) / reopen closed page |
| ⌃Tab / ⌃⇧Tab | Next / previous page in the sidebar |
| ⌘1…⌘9 | Go to that trail's first page; again, to its last page, and back |
| ⌘F, ⌘G / ⇧⌘G | Find in page, next / previous match |
| ⌘[ / ⌘] | Back / forward within a page |
| ⌘R, ⌘= ⌘- ⌘0 | Reload, zoom |
| ⌥⌘C | Developer console (Web Inspector) |
| ⌘. | Settings (trail cap) |
| ⌘, | Edit config |

Clicking a link opens it as a new page beneath the current one; ⌘-click or middle-click opens it there without leaving the page you are on. A middle-click on anything else is a click whose navigation, if it starts one, opens in the background too. Middle-click a page in the sidebar to close it. Drag a page in the sidebar onto another to move it (with everything beneath it) before, after or inside that page, or use Trails → Move Page Up / Down, Indent, Outdent. At the trail cap a quiet 🧠 count sits at the foot of the sidebar. Each page shows its site's icon. Each trail has its own colour, a rail down the sidebar and its Trails menu dot, and keeps it while other trails close or move. Double-click a page to rename it. Drag the sidebar's edge to resize it. Files a page cannot show are saved to Downloads. Typing an address with ⌘L, submitting a form, or a redirect changes the current page in place. Only recently shown pages stay loaded; the rest reload when selected. Trails are saved after every change in `trails.json` beside the config.

Mako's own shortcuts (⌘T ⌥⌘T ⇧⌘T ⌘W ⌘L ⌘1…⌘9 ⌘. ⌘, ⌥⌘C ⌃Tab) win over pages; every other shortcut goes to the page first, so web editors keep ⌘Z.

## Icon

`script/icon design/icon-variants/<variant>.png` regenerates `app/Resources/AppIcon.icns`. Six variants were generated with `gpt-image-2.5-sunburst`.

## Releases

CI (`.github/workflows/ci.yml`) runs the Rust tests, the core performance budget, the app build, DMG packaging, and `doc-check` on every pull request and push. When CI passes on `main`, `.github/workflows/release.yml` builds `Mako-0.1.<run>.dmg` and publishes it as a GitHub Release. Release builds are ad hoc signed and not notarized: on first launch, right-click Mako.app and choose Open. The UI checks (`verify-mako` smoke, perf) need a Mac with Accessibility and Screen Recording permission, so they run locally, not in CI.

    script/bundle && script/dmg      # local DMG: build/Mako-<version>.dmg

## Passkeys

WebKit only runs passkey (WebAuthn) requests in apps that hold Apple's restricted `com.apple.developer.web-browser.public-key-credential` entitlement; without it every site's passkey prompt fails with `NotAllowedError`, and signing with the entitlement but no profile makes macOS kill the app at launch. To enable passkeys:

1. Wego's Account Holder (team H38F4QZT8M) registers the App ID `com.wego.mako` and requests the entitlement at <https://developer.apple.com/contact/request/macos-browsers-passkeys/>. Apple reviews it against its web-browser criteria.
2. Once granted, create a macOS development (or Developer ID) provisioning profile for `com.wego.mako` that includes the entitlement, and download it.
3. Build with it:

       SIGN_IDENTITY="<cert from the same team>" PROVISIONING_PROFILE=path/to/Mako.provisionprofile script/bundle

   `script/bundle` refuses a profile that is not for macOS, not for `com.wego.mako`, or lacks the entitlement.

Verification copies (`control-mako`) never get passkeys: they are re-signed ad hoc under their own bundle IDs.

## Scripting and agents

`docs/control.md` documents how to drive Mako from scripts or agents: launching an isolated instance, reading tabs and page text, pressing menus and buttons, and the AX identifiers Mako exposes.

## Verification

The `verify-mako` skill (`.claude/skills/verify-mako/`) launches an isolated instance (`MAKO_CONFIG` points at a throwaway config) and drives it through the accessibility API. Needs Accessibility and Screen Recording permission for the terminal.

## Config

`~/.config/mako/config`, re-read on every navigation:

    max_trails = 3                         # trails (top-level pages), 1–9; pages within a trail are unlimited
    restore_session = true                 # keep trails (and Undo Close) across restarts (default)
    search = https://duckduckgo.com/?q=%s
    block x.com                            # always, includes subdomains and embeds (iframes)
    block youtube.com 09:00-18:00 weekdays # days: mon-fri, sat,sun, weekends, daily
