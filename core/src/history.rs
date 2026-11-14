//! History: the pages visited, and what the address bar suggests from them.
//!
//! Pure like the trails: every function takes the history and the time (`now`, unix
//! seconds) and returns its answer. The shell reads the clock and reads and writes the file.

use crate::trails::{Id, Row};
use crate::{blocked, Config};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

pub const VERSION: u32 = 1;
/// Past this, each new address pushes out the entry with the lowest score.
pub const MAX_ENTRIES: usize = 5_000;
pub const MAX_SUGGESTIONS: usize = 8;
/// A visit counts half as much after this long.
pub const HALF_LIFE_SECS: f64 = 30.0 * 86_400.0;

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct History {
    pub version: u32,
    pub entries: Vec<Entry>,
}

/// One address, however often it was visited.
#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct Entry {
    pub url: String,
    pub title: String,
    pub visits: u32,
    /// Unix seconds.
    pub last_visit: u64,
}

impl Default for History {
    fn default() -> Self {
        History { version: VERSION, entries: vec![] }
    }
}

/// When a visit happened: unix seconds for the record, and the local weekday (0 = Monday)
/// and minute of the day for the blocklist's schedules.
#[derive(Clone, Copy, Debug)]
pub struct Moment {
    pub now: u64,
    pub weekday: u8,
    pub minute: u16,
}

/// One row under the address bar.
#[derive(Serialize, Clone, PartialEq, Debug)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Suggestion {
    /// A page already open in a trail: picking it goes there instead of loading it again.
    OpenPage { id: Id, color: u8, title: String, url: String },
    History { title: String, url: String },
}

/// Parses a saved history; anything it cannot read is an error, never a silent reset.
pub fn load(json: &str) -> Result<History, String> {
    let history: History = serde_json::from_str(json).map_err(|e| e.to_string())?;
    if history.version != VERSION {
        return Err(format!("version {} (this build reads {VERSION})", history.version));
    }
    Ok(history)
}

pub fn save(history: &History) -> String {
    serde_json::to_string(history).expect("history is plain data")
}

/// Frecency: `(1 + ln visits) × 0.5^(age ÷ 30 days)`. Counting visits by their logarithm
/// keeps one habit from burying everything else; the half-life lets old habits fade.
pub fn score(entry: &Entry, now: u64) -> f64 {
    let age = now.saturating_sub(entry.last_visit) as f64;
    (1.0 + f64::from(entry.visits.max(1)).ln()) * 0.5f64.powf(age / HALF_LIFE_SECS)
}

/// The address a visit is kept under: web pages only, without the `#fragment`, which names a
/// place within the same page.
fn address(url: &str) -> Option<&str> {
    let lower = url.get(..8)?.to_ascii_lowercase();
    (lower.starts_with("http://") || lower.starts_with("https://")).then(|| url.split('#').next().unwrap())
}

/// The history after a page finished loading. Unchanged when history is off, the address is
/// not a web page, or its host is blocked right now.
pub fn visit(cfg: &Config, mut history: History, url: &str, title: &str, at: Moment) -> History {
    let Some(url) = address(url).filter(|_| cfg.remember_history) else { return history };
    if blocked(cfg, &Page::of(url).host, at.weekday, at.minute).is_some() {
        return history;
    }
    match history.entries.iter_mut().find(|e| e.url == url) {
        Some(entry) => {
            entry.visits = entry.visits.saturating_add(1);
            entry.last_visit = at.now;
            if !title.is_empty() {
                entry.title = title.into();
            }
        }
        None => {
            if history.entries.len() >= MAX_ENTRIES {
                let lowest = (0..history.entries.len()).min_by(|a, b| score(&history.entries[*a], at.now).total_cmp(&score(&history.entries[*b], at.now)));
                history.entries.swap_remove(lowest.unwrap());
            }
            history.entries.push(Entry { url: url.into(), title: title.into(), visits: 1, last_visit: at.now });
        }
    }
    history
}

/// A page's title arrived or changed after it loaded: the entry takes it, with no new visit.
pub fn retitle(mut history: History, url: &str, title: &str) -> History {
    if let Some(entry) = address(url).filter(|_| !title.is_empty()).and_then(|url| history.entries.iter_mut().find(|e| e.url == url)) {
        entry.title = title.into();
    }
    history
}

/// Up to eight rows for what is typed: open pages that match first, then history by match
/// quality × frecency. Nothing for an empty query. With history off, open pages only.
pub fn suggest(cfg: &Config, query: &str, history: &History, open: &[Row], now: u64) -> Vec<Suggestion> {
    let words: Vec<String> = query.split_whitespace().map(str::to_lowercase).collect();
    if words.is_empty() {
        return vec![];
    }
    let mut pages: Vec<(u32, &Row)> = open.iter().map(|row| (quality(&words, &Page::of(&row.url), &row.label.to_lowercase()), row)).filter(|(q, _)| *q > 0).collect();
    pages.sort_by_key(|(q, _)| std::cmp::Reverse(*q));
    pages.truncate(MAX_SUGGESTIONS);
    let mut found: Vec<Suggestion> =
        pages.iter().map(|(_, row)| Suggestion::OpenPage { id: row.id, color: row.color, title: row.label.clone(), url: row.url.clone() }).collect();
    if !cfg.remember_history || found.len() == MAX_SUGGESTIONS {
        return found;
    }
    let is_open: HashSet<&str> = open.iter().map(|row| same_page(&row.url)).collect();
    let mut ranked: Vec<(f64, &Entry)> = history
        .entries
        .iter()
        .filter_map(|entry| {
            let q = quality(&words, &Page::of(&entry.url), &entry.title.to_lowercase());
            (q > 0 && !is_open.contains(same_page(&entry.url))).then(|| (f64::from(q) * score(entry, now), entry))
        })
        .collect();
    ranked.sort_by(|a, b| b.0.total_cmp(&a.0).then(b.1.last_visit.cmp(&a.1.last_visit)));
    found.extend(ranked.iter().take(MAX_SUGGESTIONS - found.len()).map(|(_, e)| Suggestion::History { title: e.title.clone(), url: e.url.clone() }));
    found
}

/// What two addresses of one page share: no `#fragment`, no trailing slash.
fn same_page(url: &str) -> &str {
    url.split('#').next().unwrap().trim_end_matches('/')
}

/// An address in lower case, cut where matching needs it.
struct Page {
    /// As written, scheme included.
    url: String,
    /// Without the scheme or a leading `www.`: what a person types.
    typed: String,
    host: String,
}

impl Page {
    fn of(url: &str) -> Page {
        let url = url.to_lowercase();
        let after_scheme = url.split_once("://").map_or(url.as_str(), |(_, rest)| rest);
        let typed = after_scheme.strip_prefix("www.").unwrap_or(after_scheme).to_string();
        let host = after_scheme.split(['/', '?', '#']).next().unwrap();
        let host = host.rsplit_once('@').map_or(host, |(_, h)| h).split(':').next().unwrap().to_string();
        Page { url, typed, host }
    }
}

/// How well every typed word matches a page, 0 when any word is missing. Per word: 4 for the
/// start of the address as typed, 3 for the start of a title word or of a part of the host,
/// 2 for the start of a word in the path, 1 for anywhere else in the title or address.
fn quality(words: &[String], page: &Page, title: &str) -> u32 {
    let mut total = 0;
    for word in words {
        let path = &page.typed[page.typed.find(['/', '?', '#']).unwrap_or(page.typed.len())..];
        total += if page.typed.starts_with(word.as_str()) || page.url.starts_with(word.as_str()) {
            4
        } else if starts_a_word(title, word) || starts_a_word(&page.host, word) {
            3
        } else if starts_a_word(path, word) {
            2
        } else if title.contains(word.as_str()) || page.typed.contains(word.as_str()) {
            1
        } else {
            return 0;
        };
    }
    total
}

fn starts_a_word(text: &str, word: &str) -> bool {
    text.match_indices(word).any(|(i, _)| !text[..i].chars().next_back().is_some_and(char::is_alphanumeric))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parse_config;
    use crate::trails::{self, Action, Trails};

    const DAY: u64 = 86_400;
    const NOW: u64 = 1_800_000_000;

    fn at(now: u64) -> Moment {
        Moment { now, weekday: 0, minute: 600 }
    }

    fn on() -> Config {
        Config::default()
    }

    fn entry(url: &str, title: &str, visits: u32, last_visit: u64) -> Entry {
        Entry { url: url.into(), title: title.into(), visits, last_visit }
    }

    fn history(entries: &[Entry]) -> History {
        History { version: VERSION, entries: entries.to_vec() }
    }

    /// One trail per (url, title), as the open pages `suggest` is given.
    fn open(pages: &[(&str, &str)]) -> Vec<Row> {
        let mut s = Trails::default();
        for (url, title) in pages {
            s = trails::apply(&s, &Action::OpenTrail { url: url.to_string() }, 9).unwrap();
            let id = s.active.unwrap();
            s = trails::apply(&s, &Action::Navigated { id, url: url.to_string(), title: title.to_string() }, 9).unwrap();
        }
        trails::pages(&s)
    }

    fn urls(found: &[Suggestion]) -> Vec<&str> {
        found.iter().map(|s| match s { Suggestion::OpenPage { url, .. } | Suggestion::History { url, .. } => url.as_str() }).collect()
    }

    #[test]
    fn a_first_visit_is_recorded_and_a_repeat_counts() {
        let h = visit(&on(), History::default(), "https://a.test/x", "A", at(NOW));
        assert_eq!(h.entries, [entry("https://a.test/x", "A", 1, NOW)]);
        let h = visit(&on(), h, "https://a.test/x", "A, renamed", at(NOW + 60));
        assert_eq!(h.entries, [entry("https://a.test/x", "A, renamed", 2, NOW + 60)], "the title follows the latest visit");
        let h = visit(&on(), h, "https://a.test/x", "", at(NOW + 120));
        assert_eq!(h.entries, [entry("https://a.test/x", "A, renamed", 3, NOW + 120)], "a visit with no title keeps the one it had");
    }

    #[test]
    fn only_web_pages_are_recorded() {
        for url in ["data:text/html,<p>x", "file:///Users/me/notes.html", "about:blank", "mailto:a@b.test", "", "ftp://a.test/"] {
            assert_eq!(visit(&on(), History::default(), url, "T", at(NOW)), History::default(), "{url}");
        }
        assert_eq!(visit(&on(), History::default(), "HTTP://a.test/", "T", at(NOW)).entries.len(), 1);
    }

    #[test]
    fn a_fragment_is_the_same_page() {
        let h = visit(&on(), History::default(), "https://a.test/doc#intro", "Doc", at(NOW));
        let h = visit(&on(), h, "https://a.test/doc#end", "Doc", at(NOW + 1));
        assert_eq!(h.entries, [entry("https://a.test/doc", "Doc", 2, NOW + 1)]);
    }

    #[test]
    fn nothing_is_recorded_with_history_off_or_for_a_blocked_host() {
        let off = parse_config("remember_history = false").config;
        assert_eq!(visit(&off, History::default(), "https://a.test/", "A", at(NOW)), History::default());
        let cfg = parse_config("block x.com\nblock yt.com 09:00-18:00 weekdays").config;
        assert_eq!(visit(&cfg, History::default(), "https://mobile.x.com/home", "X", at(NOW)), History::default());
        assert_eq!(visit(&cfg, History::default(), "https://yt.com/", "YT", Moment { now: NOW, weekday: 0, minute: 600 }), History::default());
        assert_eq!(visit(&cfg, History::default(), "https://yt.com/", "YT", Moment { now: NOW, weekday: 5, minute: 600 }).entries.len(), 1, "outside its window");
    }

    #[test]
    fn a_late_title_updates_the_entry_without_a_visit() {
        let h = visit(&on(), History::default(), "https://a.test/app#inbox", "", at(NOW));
        let h = retitle(h, "https://a.test/app#inbox", "Inbox (3)");
        assert_eq!(h.entries, [entry("https://a.test/app", "Inbox (3)", 1, NOW)]);
        assert_eq!(retitle(h.clone(), "https://never.test/", "Nope"), h, "no entry, no change");
        assert_eq!(retitle(h.clone(), "https://a.test/app", ""), h, "an empty title is not news");
    }

    #[test]
    fn score_rises_with_visits_and_halves_every_thirty_days() {
        let fresh = entry("https://a.test/", "", 1, NOW);
        assert_eq!(score(&fresh, NOW), 1.0);
        assert!(score(&entry("https://a.test/", "", 5, NOW), NOW) > score(&fresh, NOW));
        let month_old = entry("https://a.test/", "", 1, NOW - 30 * DAY);
        assert!((score(&month_old, NOW) - 0.5).abs() < 1e-9);
        assert_eq!(score(&entry("https://a.test/", "", 1, NOW + 500), NOW), 1.0, "a clock set back is no age at all");
        let habit = entry("https://a.test/", "", 100, NOW - 60 * DAY);
        assert!(score(&habit, NOW) > score(&fresh, NOW), "a hundred visits two months ago still beat one today");
        assert!(score(&entry("https://a.test/", "", 100, NOW - 120 * DAY), NOW) < score(&fresh, NOW), "but not four months ago");
    }

    #[test]
    fn at_the_cap_the_lowest_score_makes_room() {
        let mut entries: Vec<Entry> = (0..MAX_ENTRIES).map(|i| entry(&format!("https://site{i}.test/"), "", 2, NOW - DAY)).collect();
        entries[1234] = entry("https://forgotten.test/", "", 1, NOW - 400 * DAY);
        let h = visit(&on(), history(&entries), "https://new.test/", "New", at(NOW));
        assert_eq!(h.entries.len(), MAX_ENTRIES);
        assert!(h.entries.iter().all(|e| e.url != "https://forgotten.test/"));
        assert!(h.entries.iter().any(|e| e.url == "https://new.test/"));
        let again = visit(&on(), h.clone(), "https://site7.test/", "", at(NOW));
        assert_eq!(again.entries.len(), MAX_ENTRIES, "a repeat visit pushes nothing out");
        assert!(again.entries.iter().any(|e| e.url == "https://new.test/"));
    }

    #[test]
    fn an_empty_query_suggests_nothing() {
        let h = history(&[entry("https://a.test/", "A", 3, NOW)]);
        let pages = open(&[("https://b.test/", "B")]);
        assert_eq!(suggest(&on(), "", &h, &pages, NOW), []);
        assert_eq!(suggest(&on(), "  \t", &h, &pages, NOW), []);
    }

    #[test]
    fn matches_title_words_and_the_address_whatever_the_case() {
        let h = history(&[
            entry("https://docs.rs/serde/latest/serde/", "serde – Rust", 1, NOW),
            entry("https://news.ycombinator.com/", "Hacker News", 1, NOW),
            entry("https://example.com/Guide/Install", "Getting started", 1, NOW),
        ]);
        let find = |q: &str| urls(&suggest(&on(), q, &h, &[], NOW)).into_iter().map(String::from).collect::<Vec<_>>();
        assert_eq!(find("HACK"), ["https://news.ycombinator.com/"], "a title word");
        assert_eq!(find("ycomb"), ["https://news.ycombinator.com/"], "a host label");
        assert_eq!(find("docs.rs/ser"), ["https://docs.rs/serde/latest/serde/"], "host and path as typed");
        assert_eq!(find("https://docs"), ["https://docs.rs/serde/latest/serde/"], "the address as copied");
        assert_eq!(find("install"), ["https://example.com/Guide/Install"], "a path word");
        assert_eq!(find("tart"), ["https://example.com/Guide/Install"], "inside a word");
        assert_eq!(find("rust serde"), ["https://docs.rs/serde/latest/serde/"], "every word must match");
        assert_eq!(find("rust hacker"), Vec::<String>::new());
        assert_eq!(find("zzz"), Vec::<String>::new());
    }

    #[test]
    fn a_word_or_host_start_beats_a_match_inside_a_word() {
        let h = history(&[
            entry("https://a.test/1", "Unmapped territory", 1, NOW),
            entry("https://maps.test/", "Directions", 1, NOW),
            entry("https://b.test/2", "Old maps of Asia", 1, NOW),
            entry("https://c.test/sitemap", "Index", 1, NOW),
        ]);
        assert_eq!(
            urls(&suggest(&on(), "map", &h, &[], NOW)),
            ["https://maps.test/", "https://b.test/2", "https://a.test/1", "https://c.test/sitemap"],
            "the host's start, a title word's start, then the two matches inside a word"
        );
    }

    #[test]
    fn frecency_orders_matches_of_equal_quality() {
        let h = history(&[
            entry("https://a.test/rust-old", "Rust old", 1, NOW - 90 * DAY),
            entry("https://a.test/rust-habit", "Rust habit", 40, NOW - 2 * DAY),
            entry("https://a.test/rust-today", "Rust today", 1, NOW),
        ]);
        assert_eq!(urls(&suggest(&on(), "rust", &h, &[], NOW)), ["https://a.test/rust-habit", "https://a.test/rust-today", "https://a.test/rust-old"]);
    }

    #[test]
    fn quality_times_frecency_lets_a_habit_outrank_a_better_match() {
        let h = history(&[
            entry("https://git.test/", "Git", 1, NOW - 20 * DAY),
            entry("https://a.test/", "My digital garden", 60, NOW),
        ]);
        assert_eq!(urls(&suggest(&on(), "git", &h, &[], NOW)), ["https://a.test/", "https://git.test/"]);
    }

    #[test]
    fn open_pages_come_first_with_their_id_and_colour() {
        let h = history(&[entry("https://rust-lang.org/", "Rust", 500, NOW)]);
        let pages = open(&[("https://a.test/", "Alpha"), ("https://b.test/rust", "Rust book")]);
        assert_eq!(
            suggest(&on(), "rust", &h, &pages, NOW),
            [
                Suggestion::OpenPage { id: 2, color: 1, title: "Rust book".into(), url: "https://b.test/rust".into() },
                Suggestion::History { title: "Rust".into(), url: "https://rust-lang.org/".into() },
            ]
        );
    }

    #[test]
    fn an_open_page_inside_a_collapsed_one_is_still_suggested_under_its_name() {
        let mut s = Trails::default();
        for action in [
            Action::OpenTrail { url: "https://a.test/".into() },
            Action::OpenChild { parent: 1, url: "https://b.test/deep".into(), select: false },
            Action::Rename { id: 2, name: Some("Tax return".into()) },
            Action::SetCollapsed { id: 1, collapsed: true },
        ] {
            s = trails::apply(&s, &action, 9).unwrap();
        }
        assert_eq!(trails::rows(&s).len(), 1);
        assert_eq!(
            suggest(&on(), "tax", &History::default(), &trails::pages(&s), NOW),
            [Suggestion::OpenPage { id: 2, color: 0, title: "Tax return".into(), url: "https://b.test/deep".into() }]
        );
    }

    #[test]
    fn a_history_address_that_is_open_shows_only_as_the_open_page() {
        let h = history(&[
            entry("https://a.test/doc", "Doc", 9, NOW),
            entry("https://a.test", "Doc home", 9, NOW),
            entry("https://a.test/docs", "Docs index", 1, NOW),
        ]);
        let pages = open(&[("https://a.test/doc#part-2", "Doc"), ("https://a.test/", "Doc home")]);
        let found = suggest(&on(), "doc", &h, &pages, NOW);
        assert_eq!(urls(&found), ["https://a.test/doc#part-2", "https://a.test/", "https://a.test/docs"]);
        assert!(matches!(found[..], [Suggestion::OpenPage { .. }, Suggestion::OpenPage { .. }, Suggestion::History { .. }]));
    }

    #[test]
    fn at_most_eight_rows() {
        let entries: Vec<Entry> = (0..30).map(|i| entry(&format!("https://a.test/page{i}"), "Page", 1, NOW - i)).collect();
        let pages = open(&[("https://b.test/page", "Page one"), ("https://c.test/page", "Page two")]);
        let found = suggest(&on(), "page", &history(&entries), &pages, NOW);
        assert_eq!(found.len(), MAX_SUGGESTIONS);
        assert_eq!(urls(&found)[..3], ["https://b.test/page", "https://c.test/page", "https://a.test/page0"]);
    }

    #[test]
    fn with_history_off_only_open_pages_are_suggested() {
        let off = parse_config("remember_history = false").config;
        let h = history(&[entry("https://a.test/rust", "Rust", 9, NOW)]);
        let pages = open(&[("https://b.test/rust", "Rust book")]);
        assert_eq!(urls(&suggest(&off, "rust", &h, &pages, NOW)), ["https://b.test/rust"]);
        assert_eq!(suggest(&off, "rust", &h, &[], NOW), []);
    }

    #[test]
    fn saves_and_loads_and_rejects_what_it_cannot_read() {
        let h = history(&[entry("https://a.test/", "A “quoted” title", 2, NOW)]);
        assert_eq!(load(&save(&h)).unwrap(), h);
        assert_eq!(load(&save(&History::default())).unwrap(), History::default());
        assert!(load("{").is_err());
        assert!(load(r#"{"version":2,"entries":[]}"#).unwrap_err().contains("version 2"));
    }

    /// The address bar asks on every keystroke, so a full history must answer well inside a
    /// frame. Run with `cargo test --release -- --ignored`; debug builds are too slow to time.
    #[test]
    #[ignore]
    fn perf_budget_suggest() {
        let words = ["rust", "news", "maps", "mail", "docs", "video", "music", "wiki", "shop", "blog"];
        let entries: Vec<Entry> = (0..MAX_ENTRIES)
            .map(|i| {
                let (a, b) = (words[i % 10], words[(i / 10) % 10]);
                entry(&format!("https://{a}{i}.example.com/{b}/article-{i}?ref=home"), &format!("{b} {a} – Article number {i} about things"), (i % 17 + 1) as u32, NOW - (i as u64 * 3_600))
            })
            .collect();
        let (h, pages) = (history(&entries), open(&[("https://a.test/", "Alpha"), ("https://docs.test/", "Docs")]));
        let queries = ["d", "do", "doc", "docs", "docs ar", "article 4", "example.com/ne", "zzzz"];
        let start = std::time::Instant::now();
        for i in 0..400 {
            std::hint::black_box(suggest(&on(), queries[i % queries.len()], &h, &pages, NOW));
        }
        let per_call = start.elapsed() / 400;
        assert!(per_call < std::time::Duration::from_millis(5), "suggest took {per_call:?} per keystroke over {MAX_ENTRIES} entries (budget 5ms)");
        println!("suggest: {per_call:?} per keystroke over {MAX_ENTRIES} entries");
    }
}
