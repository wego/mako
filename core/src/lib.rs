//! Mako's functional core: omnibox resolution and focus policy.
//! Pure functions only – the Swift shell owns I/O, clocks and the web view.

mod ffi;

pub const DEFAULT_MAX_TABS: usize = 3;
pub const DEFAULT_SEARCH: &str = "https://www.google.com/search?q=%s";

#[derive(Debug, PartialEq)]
pub struct Config {
    pub max_tabs: usize,
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
        Config { max_tabs: DEFAULT_MAX_TABS, restore_session: true, search: DEFAULT_SEARCH.into(), blocks: vec![] }
    }
}

/// Config format, one directive per line, `#` comments:
///   max_tabs = 3
///   restore_session = true
///   search = https://duckduckgo.com/?q=%s
///   block x.com                      # always
///   block youtube.com 09:00-18:00 mon-fri
pub fn parse_config(text: &str) -> Result<Config, String> {
    let mut cfg = Config::default();
    for (i, raw) in text.lines().enumerate() {
        let line = raw.split('#').next().unwrap().trim();
        if line.is_empty() {
            continue;
        }
        let err = |msg: &str| format!("config line {}: {msg}: `{line}`", i + 1);
        if let Some((key, val)) = line.split_once('=') {
            let val = val.trim();
            match key.trim() {
                "max_tabs" => {
                    cfg.max_tabs = val.parse().ok().filter(|n| *n > 0).ok_or_else(|| err("max_tabs must be a positive integer"))?
                }
                "restore_session" => {
                    cfg.restore_session = val.parse().map_err(|_| err("restore_session must be true or false"))?
                }
                "search" if val.contains("%s") => cfg.search = val.into(),
                "search" => return Err(err("search must contain %s")),
                _ => return Err(err("unknown setting")),
            }
            continue;
        }
        let mut parts = line.split_whitespace();
        if parts.next() != Some("block") {
            return Err(err("expected `block <domain> [HH:MM-HH:MM] [days]` or `key = value`"));
        }
        let domain = parts.next().ok_or_else(|| err("missing domain"))?.trim_start_matches("*.").to_lowercase();
        let window = match parts.next() {
            None => None,
            Some(range) => {
                let (start, end) = range.split_once('-').ok_or_else(|| err("bad time range"))?;
                let days = match parts.next() {
                    None => 0b111_1111,
                    Some(d) => parse_days(d).ok_or_else(|| err("bad days"))?,
                };
                Some(Window {
                    days,
                    start: parse_hhmm(start).ok_or_else(|| err("bad start time"))?,
                    end: parse_hhmm(end).ok_or_else(|| err("bad end time"))?,
                })
            }
        };
        if parts.next().is_some() {
            return Err(err("trailing input"));
        }
        cfg.blocks.push(Block { domain, window });
    }
    Ok(cfg)
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

    fn cfg(t: &str) -> Config {
        parse_config(t).unwrap()
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
        let c = cfg("# focus\nmax_tabs = 2\nsearch = https://d.com/?q=%s\nblock *.X.com\nblock yt.com 09:00-18:00 mon-fri # work\n");
        assert_eq!(c.max_tabs, 2);
        assert!(c.restore_session);
        assert!(!cfg("restore_session = false").restore_session);
        assert_eq!(c.search, "https://d.com/?q=%s");
        assert_eq!(c.blocks[0], Block { domain: "x.com".into(), window: None });
        assert_eq!(c.blocks[1].window, Some(Window { days: 0b1_1111, start: 540, end: 1080 }));
        assert_eq!(cfg("").max_tabs, DEFAULT_MAX_TABS);
        assert_eq!(cfg("block a.com 22:00-02:00 sat,sun").blocks[0].window.as_ref().unwrap().days, 0b110_0000);
        assert_eq!(cfg("block a.com 00:00-24:00 fri-mon").blocks[0].window.as_ref().unwrap().days, 0b111_0001);
    }

    #[test]
    fn rejects_bad_config_with_line_number() {
        for bad in ["max_tabs = 0", "restore_session = maybe", "search = x", "block", "block a.com 9-5", "block a.com 09:00-25:00", "block a.com 09:00-17:00 funday", "blok a.com", "colour = red"] {
            assert!(parse_config(&format!("\n{bad}")).unwrap_err().starts_with("config line 2:"), "{bad}");
        }
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
            let c = parse_config(&text).unwrap();
            std::hint::black_box(blocked(&c, &format!("www.site{}.example", i % 600), 0, 600));
        }
        let per_call = start.elapsed() / 1_000;
        assert!(per_call < std::time::Duration::from_micros(200), "parse+check took {per_call:?} per navigation (budget 200µs)");
        println!("parse+check: {per_call:?} per navigation with 500 block rules");
    }
}
