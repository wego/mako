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
| ⌘1–9 | Switch tab |
| ⌘[ / ⌘] | Back / forward |
| ⌘R, ⌘= ⌘- ⌘0 | Reload, zoom |
| ⌘, | Edit config |

Links that try to open a new window load in the current tab.

## Config

`~/.config/mako/config`, re-read on every navigation:

    max_tabs = 3
    search = https://duckduckgo.com/?q=%s
    block x.com                            # always, includes subdomains
    block youtube.com 09:00-18:00 weekdays # days: mon-fri, sat,sun, weekends, daily
