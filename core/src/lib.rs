//! Mako's functional core: omnibox resolution and focus policy.
//! Pure functions only – the Swift shell owns I/O, clocks and the web view.

mod ffi;
pub mod trails;

pub const DEFAULT_SEARCH: &str = "https://www.google.com/search?q=%s";

#[derive(Debug, PartialEq)]
pub struct Config {
    pub max_trails: usize,
    pub restore_session: bool,
    pub search: String,
    pub blocks: Vec<Block>,
}

#[derive(Debug, PartialEq)]
pub struct Block {
    pub domain: String,
    pub window: Option<Window>,
}

/// Days as a bitmask (bit 0 = Monday). Minutes since local midnight.
/// `start > end` wraps past midnight; the day check uses the current day.
#[derive(Debug, PartialEq)]
pub struct Window {
    pub days: u8,
    pub start: u16,
    pub end: u16,
}

impl Default for Config {
    fn default() -> Self {
        Config { max_trails: trails::DEFAULT_MAX_TRAILS, restore_session: true, search: DEFAULT_SEARCH.into(), blocks: vec![] }
    }
}

/// Config format, one directive per line, `#` comments:
///   max_trails = 3
///   restore_session = true
///   search = https://duckduckgo.com/?q=%s
///   block x.com                      # always
///   block youtube.com 09:00-18:00 mon-fri
/// `text` with `key = value` set: the first line setting `key` is rewritten (its comment
/// dropped), otherwise the line is appended. Everything else is kept as written.
pub fn set_setting(text: &str, key: &str, value: &str) -> String {
    let sets = |raw: &str| raw.split('#').next().unwrap().split_once('=').is_some_and(|(k, _)| k.trim() == key);
    let line = format!("{key} = {value}");
    let mut lines: Vec<&str> = text.lines().collect();
    match lines.iter().position(|l| sets(l)) {
        Some(i) => lines[i] = &line,
        None => lines.push(&line),
    }
    lines.join("\n") + "\n"
}

/// The config read line by line, and every line it could not use.
#[derive(Debug, PartialEq)]
pub struct Parsed {
    pub config: Config,
    pub issues: Vec<Issue>,
}

/// One unusable line: `config line <line>: <why>: `<text>``.
#[derive(Debug, PartialEq)]
pub struct Issue {
    pub line: usize,
    pub message: String,
}

/// Never fails: each line applies on its own, so a typo costs only its own line.
pub fn parse_config(text: &str) -> Parsed {
    let mut config = Config::default();
    let mut issues = vec![];
    for (i, raw) in text.lines().enumerate() {
        let line = raw.split('#').next().unwrap().trim();
        if line.is_empty() {
            continue;
        }
        if let Err(why) = apply_line(&mut config, line) {
            issues.push(Issue { line: i + 1, message: format!("config line {}: {why}: `{line}`", i + 1) });
        }
    }
    Parsed { config, issues }
}

/// Applies one directive to `cfg`. On error, settings keep their defaults; a block
/// line with a domain still blocks it, at all times, since the schedule is unknown.
fn apply_line(cfg: &mut Config, line: &str) -> Result<(), String> {
    if let Some((key, val)) = line.split_once('=') {
        let val = val.trim();
        match key.trim() {
            // Left over from the tabs era.
            "max_tabs" => {}
            "max_trails" => {
                let n: usize = val.parse().ok().filter(|n| *n > 0).ok_or("max_trails must be a positive integer")?;
                cfg.max_trails = n.min(trails::MAX_TRAILS)
            }
            "restore_session" => cfg.restore_session = val.parse().map_err(|_| "restore_session must be true or false")?,
            "search" if val.contains("%s") => cfg.search = val.into(),
            "search" => return Err("search must contain %s".into()),
            _ => return Err("unknown setting".into()),
        }
        return Ok(());
    }
    let mut parts = line.split_whitespace();
    if parts.next() != Some("block") {
        return Err("expected `block <domain> [HH:MM-HH:MM] [days]` or `key = value`".into());
    }
    let domain = parts.next().ok_or("missing domain")?.trim_start_matches("*.").to_lowercase();
    let (window, problem) = match parse_window(parts.collect()) {
        Ok(window) => (window, None),
        Err(why) => (None, Some(format!("{why} – blocking it at all times"))),
    };
    cfg.blocks.push(Block { domain, window });
    problem.map_or(Ok(()), Err)
}

/// `[HH:MM-HH:MM [days]]`; nothing means always.
fn parse_window(schedule: Vec<&str>) -> Result<Option<Window>, &'static str> {
    let (range, days) = match schedule[..] {
        [] => return Ok(None),
        [range] => (range, None),
        [range, days] => (range, Some(days)),
        _ => return Err("trailing input"),
    };
    let (start, end) = range.split_once('-').ok_or("bad time range")?;
    Ok(Some(Window {
        days: days.map_or(Some(0b111_1111), parse_days).ok_or("bad days")?,
        start: parse_hhmm(start).ok_or("bad start time")?,
        end: parse_hhmm(end).ok_or("bad end time")?,
    }))
}

fn parse_hhmm(s: &str) -> Option<u16> {
    let (h, m) = s.split_once(':')?;
    let (h, m): (u16, u16) = (h.parse().ok()?, m.parse().ok()?);
    (h <= 24 && m < 60 && h * 60 + m <= 1440).then_some(h * 60 + m)
}

const DAYS: [&str; 7] = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];

fn parse_days(s: &str) -> Option<u8> {
    let idx = |d: &str| DAYS.iter().position(|x| *x == d);
    match s {
        "daily" => return Some(0b111_1111),
        "weekdays" => return Some(0b001_1111),
        "weekends" => return Some(0b110_0000),
        _ => {}
    }
    let mut mask = 0u8;
    for part in s.split(',') {
        match part.split_once('-') {
            Some((a, b)) => {
                let (a, b) = (idx(a)?, idx(b)?);
                let mut d = a;
                loop {
                    mask |= 1 << d;
                    if d == b {
                        break;
                    }
                    d = (d + 1) % 7;
                }
            }
            None => mask |= 1 << idx(part)?,
        }
    }
    Some(mask)
}

/// Returns a human reason if `host` is blocked at (weekday 0=Mon, minute of day).
pub fn blocked(cfg: &Config, host: &str, weekday: u8, minute: u16) -> Option<String> {
    let host = host.trim_end_matches('.').to_lowercase();
    cfg.blocks.iter().find_map(|b| {
        let matches = host == b.domain || host.ends_with(&format!(".{}", b.domain));
        if !matches {
            return None;
        }
        match &b.window {
            None => Some(format!("{} is blocked.", b.domain)),
            Some(w) => {
                let in_day = w.days & (1 << weekday) != 0;
                let in_time = if w.start <= w.end {
                    (w.start..w.end).contains(&minute)
                } else {
                    minute >= w.start || minute < w.end
                };
                (in_day && in_time).then(|| match w.end {
                    1440 => format!("{} is blocked until midnight.", b.domain),
                    e => format!("{} is blocked until {:02}:{:02}.", b.domain, e / 60, e % 60),
                })
            }
        }
    })
}

/// Turns omnibox input into a URL: explicit URL, bare domain, or search.
pub fn resolve(cfg: &Config, input: &str) -> Option<String> {
    let s = input.trim();
    if s.is_empty() {
        return None;
    }
    if s.contains("://") || s.starts_with("about:") || s.starts_with("data:") {
        return Some(s.into());
    }
    let looks_like_host = !s.contains(char::is_whitespace) && {
        let host = s.split(['/', '?', '#']).next().unwrap();
        let name = host.rsplit_once(':').map_or(host, |(h, port)| {
            if port.chars().all(|c| c.is_ascii_digit()) { h } else { host }
        });
        name == "localhost"
            || name.parse::<std::net::Ipv4Addr>().is_ok()
            || name.rsplit_once('.').is_some_and(|(l, tld)| !l.is_empty() && tld.len() >= 2 && tld.chars().all(|c| c.is_ascii_alphabetic()))
    };
    if looks_like_host {
        let local = s.starts_with("localhost") || s.starts_with("127.");
        return Some(format!("{}://{s}", if local { "http" } else { "https" }));
    }
    Some(cfg.search.replace("%s", &encode(s)))
}

fn encode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            b' ' => "+".into(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A config with no issues: every line in `t` must be valid.
    fn cfg(t: &str) -> Config {
        let parsed = parse_config(t);
        assert_eq!(parsed.issues, [], "{t}");
        parsed.config
    }

    fn always(domain: &str) -> Block {
        Block { domain: domain.into(), window: None }
    }

    fn blocked_all_week(c: &Config, host: &str) -> bool {
        (0..7).all(|day| [0, 9 * 60, 12 * 60, 23 * 60 + 59].iter().all(|m| blocked(c, host, day, *m).is_some()))
    }

    #[test]
    fn resolves_urls_domains_and_searches() {
        let c = Config::default();
        assert_eq!(resolve(&c, "  "), None);
        assert_eq!(resolve(&c, "https://a.com/x").unwrap(), "https://a.com/x");
        assert_eq!(resolve(&c, "example.com").unwrap(), "https://example.com");
        assert_eq!(resolve(&c, "news.ycombinator.com/item?id=1").unwrap(), "https://news.ycombinator.com/item?id=1");
        assert_eq!(resolve(&c, "localhost:3000").unwrap(), "http://localhost:3000");
        assert_eq!(resolve(&c, "127.0.0.1:8080/a").unwrap(), "http://127.0.0.1:8080/a");
        assert_eq!(resolve(&c, "rust lifetimes").unwrap(), "https://www.google.com/search?q=rust+lifetimes");
        assert_eq!(resolve(&c, "c++ & co").unwrap(), "https://www.google.com/search?q=c%2B%2B+%26+co");
        assert_eq!(resolve(&c, "v1.2").unwrap(), "https://www.google.com/search?q=v1.2");
        assert_eq!(resolve(&c, "about:blank").unwrap(), "about:blank");
    }

    #[test]
    fn parses_config() {
        let c = cfg("# focus\nsearch = https://d.com/?q=%s\nblock *.X.com\nblock yt.com 09:00-18:00 mon-fri # work\n");
        assert!(c.restore_session);
        assert_eq!((c.max_trails, cfg("max_trails = 4").max_trails), (3, 4));
        assert!(!cfg("restore_session = false").restore_session);
        assert_eq!(c.search, "https://d.com/?q=%s");
        assert_eq!(c.blocks[0], Block { domain: "x.com".into(), window: None });
        assert_eq!(c.blocks[1].window, Some(Window { days: 0b1_1111, start: 540, end: 1080 }));
        assert_eq!(cfg("block a.com 22:00-02:00 sat,sun").blocks[0].window.as_ref().unwrap().days, 0b110_0000);
        assert_eq!(cfg("block a.com 00:00-24:00 fri-mon").blocks[0].window.as_ref().unwrap().days, 0b111_0001);
    }

    #[test]
    fn a_leftover_max_tabs_line_keeps_the_blocklist() {
        let c = cfg("max_tabs = 3\nblock x.com\n");
        assert_eq!(c.blocks, [Block { domain: "x.com".into(), window: None }]);
        assert_eq!(c.max_trails, trails::DEFAULT_MAX_TRAILS);
    }

    #[test]
    fn max_trails_above_the_nine_trail_colours_is_capped_and_keeps_the_blocklist() {
        let c = cfg("max_trails = 10\nblock x.com\n");
        assert_eq!(c.max_trails, trails::MAX_TRAILS);
        assert_eq!(c.blocks, [Block { domain: "x.com".into(), window: None }]);
        assert_eq!(cfg("max_trails = 9").max_trails, 9);
    }

    #[test]
    fn reports_each_bad_line_with_its_number_and_text() {
        for bad in ["max_trails = 0", "restore_session = maybe", "search = x", "block", "block a.com 9-5", "block a.com 09:00-25:00", "block a.com 09:00-17:00 funday", "blok a.com", "colour = red"] {
            let issues = parse_config(&format!("\n{bad}")).issues;
            assert_eq!(issues.len(), 1, "{bad}");
            assert_eq!(issues[0].line, 2, "{bad}");
            assert!(issues[0].message.starts_with("config line 2: "), "{bad}: {}", issues[0].message);
            assert!(issues[0].message.ends_with(&format!(": `{bad}`")), "{bad}: {}", issues[0].message);
        }
    }

    #[test]
    fn a_typo_line_keeps_the_blocklist() {
        let parsed = parse_config("colour = red\nblock x.com\n");
        assert_eq!(parsed.config.blocks, [always("x.com")]);
        assert!(blocked_all_week(&parsed.config, "x.com"));
        assert_eq!(parsed.issues, [Issue { line: 1, message: "config line 1: unknown setting: `colour = red`".into() }]);
    }

    #[test]
    fn a_bad_schedule_blocks_the_domain_at_all_times() {
        for line in ["block youtube.com 09:00-25:00", "block youtube.com 09:00-17:00 funday", "block youtube.com 9-5", "block youtube.com 09:00-17:00 mon extra"] {
            let parsed = parse_config(line);
            assert_eq!(parsed.config.blocks, [always("youtube.com")], "{line}");
            assert!(blocked_all_week(&parsed.config, "www.youtube.com"), "{line}");
            assert_eq!(parsed.issues.len(), 1, "{line}");
            assert_eq!(parsed.issues[0].line, 1, "{line}");
        }
    }

    #[test]
    fn a_block_line_without_a_domain_is_an_issue_and_other_blocks_stay() {
        let parsed = parse_config("block x.com\nblock\nblock y.com\n");
        assert_eq!(parsed.config.blocks, [always("x.com"), always("y.com")]);
        assert_eq!(parsed.issues.iter().map(|i| i.line).collect::<Vec<_>>(), [2]);
    }

    #[test]
    fn a_bad_value_keeps_that_default_and_applies_every_other_line() {
        let parsed = parse_config("max_trails = abc\nrestore_session = false\nsearch = https://d.com/?q=%s\nblock x.com\n");
        assert_eq!(parsed.config.max_trails, trails::DEFAULT_MAX_TRAILS);
        assert!(!parsed.config.restore_session);
        assert_eq!(parsed.config.search, "https://d.com/?q=%s");
        assert_eq!(parsed.config.blocks, [always("x.com")]);
        assert_eq!(parsed.issues, [Issue { line: 1, message: "config line 1: max_trails must be a positive integer: `max_trails = abc`".into() }]);
    }

    #[test]
    fn several_bad_lines_are_all_reported_in_file_order() {
        let parsed = parse_config("# mine\ncolour = red\nblock x.com\nmax_trails = -1\nblok y.com\n\nblock z.com 25:00-26:00\n");
        assert_eq!(parsed.issues.iter().map(|i| i.line).collect::<Vec<_>>(), [2, 4, 5, 7]);
        assert_eq!(parsed.config.blocks, [always("x.com"), always("z.com")]);
    }

    #[test]
    fn blocks_by_domain_and_window() {
        let c = cfg("block x.com\nblock yt.com 09:00-18:00 weekdays\nblock late.com 22:00-02:00");
        let (mon, sat) = (0, 5);
        assert!(blocked(&c, "x.com", mon, 0).is_some());
        assert!(blocked(&c, "mobile.X.com.", sat, 0).is_some());
        assert!(blocked(&c, "notx.com", mon, 0).is_none());
        assert_eq!(blocked(&c, "www.yt.com", mon, 9 * 60).unwrap(), "yt.com is blocked until 18:00.");
        assert!(blocked(&c, "yt.com", mon, 18 * 60).is_none());
        assert!(blocked(&c, "yt.com", sat, 12 * 60).is_none());
        assert!(blocked(&c, "late.com", mon, 23 * 60).is_some());
        assert!(blocked(&c, "late.com", mon, 60).is_some());
        assert!(blocked(&c, "late.com", mon, 12 * 60).is_none());
        assert_eq!(blocked(&cfg("block a.com 20:00-24:00"), "a.com", mon, 21 * 60).unwrap(), "a.com is blocked until midnight.");
    }

    /// The shell re-parses the config on every navigation, so parse + check is the hot path.
    /// Run with `cargo test --release -- --ignored`; debug builds are too slow to time.
    #[test]
    #[ignore]
    fn perf_budget_parse_and_check() {
        let text: String = (0..500).map(|i| format!("block site{i}.example 09:00-18:00 weekdays\n")).collect();
        let start = std::time::Instant::now();
        for i in 0..1_000 {
            let c = parse_config(&text).config;
            std::hint::black_box(blocked(&c, &format!("www.site{}.example", i % 600), 0, 600));
        }
        let per_call = start.elapsed() / 1_000;
        assert!(per_call < std::time::Duration::from_micros(200), "parse+check took {per_call:?} per navigation (budget 200µs)");
        println!("parse+check: {per_call:?} per navigation with 500 block rules");
    }

    #[test]
    fn set_setting_rewrites_or_appends() {
        let text = "# Mako config\nmax_trails = 3   # cap\nblock x.com\n";
        assert_eq!(set_setting(text, "max_trails", "5"), "# Mako config\nmax_trails = 5\nblock x.com\n");
        assert_eq!(set_setting("block x.com", "max_trails", "2"), "block x.com\nmax_trails = 2\n");
        assert_eq!(set_setting("", "max_trails", "2"), "max_trails = 2\n");
        assert_eq!(set_setting("# max_trails = 9\n", "max_trails", "2"), "# max_trails = 9\nmax_trails = 2\n", "comments are not settings");
        assert_eq!(cfg(&set_setting(text, "max_trails", "7")).max_trails, 7);
    }
}
