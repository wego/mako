# Mako

A minimal macOS browser for focus: a few tabs, no tab bar, a blocklist.
Swift/AppKit shell over WKWebView; policy and omnibox logic in a small Rust core.

## Build

    script/bundle          # -> build/Mako.app (Rust core + Swift shell, ad-hoc signed)
    open build/Mako.app
    cargo test --manifest-path core/Cargo.toml

## Keys

| Key | Action |
| --- | --- |
| ⌘L | Omnibox (also lists open tabs) |
| ⌘T / ⌘W | New tab (refused at the cap) / close tab |
| ⌘1–9 / Tabs menu | Switch tab (the menu lists open tabs by name) |
| ⌘[ / ⌘] | Back / forward |
| ⌘R, ⌘= ⌘- ⌘0 | Reload, zoom |
| ⌥⌘C | Developer console (Web Inspector) |
| ⌘, | Edit config |

Links that try to open a new window load in the current tab. Mako's own shortcuts (⌘T ⌘W ⌘L ⌘, ⌘1–9 ⌥⌘C) win over pages; every other shortcut goes to the page first, so web editors keep ⌘Z.

## Icon

`script/icon design/icon-variants/<variant>.png` regenerates `app/Resources/AppIcon.icns`. Six variants were generated with `gpt-image-2.5-sunburst`.

## Passkeys

WebKit only runs passkey (WebAuthn) requests in apps that hold Apple's restricted `com.apple.developer.web-browser.public-key-credential` entitlement; without it every site's passkey prompt fails with `NotAllowedError`, and signing with the entitlement but no profile makes macOS kill the app at launch. To enable passkeys:

1. The Account Holder of an Apple Developer organization account registers the App ID `com.chuyeow.mako` and requests the entitlement at <https://developer.apple.com/contact/request/macos-browsers-passkeys/>. Apple reviews it against its web-browser criteria.
2. Once granted, create a macOS development (or Developer ID) provisioning profile for `com.chuyeow.mako` that includes the entitlement, and download it.
3. Build with it:

       SIGN_IDENTITY="<cert from the same team>" PROVISIONING_PROFILE=path/to/Mako.provisionprofile script/bundle

   `script/bundle` refuses a profile that is not for macOS, not for `com.chuyeow.mako`, or lacks the entitlement.

Verification copies (`control-mako`) never get passkeys: they are re-signed ad hoc under their own bundle IDs.

## Scripting and agents

`docs/control.md` documents how to drive Mako from scripts or agents: launching an isolated instance, reading tabs and page text, pressing menus and buttons, and the AX identifiers Mako exposes.

## Verification

The `verify-mako` skill (`.claude/skills/verify-mako/`) launches an isolated instance (`MAKO_CONFIG` points at a throwaway config) and drives it through the accessibility API. Needs Accessibility and Screen Recording permission for the terminal.

## Config

`~/.config/mako/config`, re-read on every navigation:

    max_tabs = 3
    restore_session = true                 # reopen last session's tabs at launch (default)
    search = https://duckduckgo.com/?q=%s
    block x.com                            # always, includes subdomains and embeds (iframes)
    block youtube.com 09:00-18:00 weekdays # days: mon-fri, sat,sun, weekends, daily
