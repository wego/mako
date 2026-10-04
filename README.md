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

## Verification

The `verify-mako` skill (`.claude/skills/verify-mako/`) launches an isolated instance (`MAKO_CONFIG` points at a throwaway config) and drives it through the accessibility API. Needs Accessibility and Screen Recording permission for the terminal.

## Config

`~/.config/mako/config`, re-read on every navigation:

    max_tabs = 3
    search = https://duckduckgo.com/?q=%s
    block x.com                            # always, includes subdomains
    block youtube.com 09:00-18:00 weekdays # days: mon-fri, sat,sun, weekends, daily
