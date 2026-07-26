//! Letterboxd overlay: harvest a handful of *public* Letterboxd accounts and
//! correlate their watched films, ratings, hearts, and watchlists to the movies
//! on disk. Everything here is read-only and in-memory — no key, no on-disk
//! state. The whole overlay is rebuilt from scratch on boot and on manual
//! Refresh; there is no polling timer (see [`Letterboxd::refresh`]).
//!
//! ## Where the data comes from
//!
//! The official API is invite-only and its terms forbid personal/overlay
//! projects, so every field is scraped from a member's public pages instead:
//!
//! - `/{user}/films/` — watched films with that member's rating (`rated-N`, N
//!   half-stars). Page 1 (the ~72 most recent) is reliable; the deeper pages
//!   (`/films/page/N/`) are the "full history" tier, which Cloudflare challenges
//!   under repeated access — [`harvest_grid`] attempts them but bails the moment
//!   it's blocked rather than hammer, so deep coverage depends on how calm the
//!   host IP is. Recent watches, ratings, and the watchlist never depend on it.
//! - `/{user}/rss/` — the latest ~50 diary entries, which uniquely carry the
//!   `memberLike` (heart) flag. This is the reliable source of ❤.
//! - `/{user}/likes/films/` — the full liked set; *best-effort only* (same
//!   Cloudflare caveat). A failure is silently tolerated (RSS covers recent ❤).
//! - `/{user}/watchlist/` — the watchlist set (page 1 reliable; deeper pages
//!   best-effort like the watch history).
//!
//! Films are keyed by a normalized `(title, year)`: the title lowercased and
//! reduced to `[a-z0-9]` (so `(500) Days of Summer` and `500 Days of Summer`
//! collapse identically) plus the four-digit year parsed from a trailing
//! `(YYYY)`. Disk entries are matched by parsing their own name the same way.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock};
use std::time::Duration;

use arc_swap::ArcSwap;
use regex::Regex;
use serde::Serialize;
use unicode_normalization::UnicodeNormalization;

/// Recognised video extensions to strip from a disk entry name before parsing
/// its title/year. Mirrors `library::VIDEO_EXTS`; kept local so the matcher is
/// self-contained.
const VIDEO_EXTS: &[&str] = &["mp4", "mkv", "mov", "webm", "m4v"];

/// Per-account dot colors, assigned by `--letterboxd` order. Distinct hues that
/// read on both the light and dark poster art. Wraps if there are more accounts
/// than colors (a "handful" is the expected case).
const PALETTE: &[&str] = &[
    "#4ade80", // green
    "#60a5fa", // blue
    "#f472b6", // pink
    "#fbbf24", // amber
    "#a78bfa", // violet
    "#22d3ee", // cyan
    "#fb7185", // rose
    "#facc15", // yellow
];

/// A browser User-Agent. Letterboxd 403s obviously-bot agents, so the harvester
/// presents itself like a normal browser (this is public data being read at a
/// polite, human-scale rate — startup + manual Refresh only).
const USER_AGENT: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 \
     (KHTML, like Gecko) Version/17.0 Safari/605.1.15";

/// A normalized film identity: `(alnum-lowercased title, four-digit year)`.
type FilmKey = (String, Option<u16>);

// --- static parsers -------------------------------------------------------

static ITEM_NAME_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"data-item-name="([^"]*)""#).unwrap());
static ITEM_SLUG_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"data-item-slug="([^"]*)""#).unwrap());
static RATED_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"rated-(\d+)").unwrap());
static RSS_TMDB_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"<tmdb:movieId>(\d+)</tmdb:movieId>").unwrap());
static YEAR_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(.*?)\s*\((\d{4})\)\s*$").unwrap());
static ENTITY_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"&#?[0-9a-zA-Z]+;").unwrap());
/// Edition / quality / scene tags that appear in disk filenames but never in a
/// Letterboxd canonical title (`… Witch Hunters UNRATED`, `… EXTENDED CUT`,
/// `… 1080p BluRay`). Stripped from *both* sides so the strip stays consistent;
/// the year guard on the matcher keeps different cuts of the same film from
/// colliding across years. Whole-word, case-insensitive.
static EDITION_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)\b(unrated|uncut|remastered|remaster|theatrical(?: cut)?|director'?s cut|extended(?: cut| edition)?|special edition|collector'?s edition|final cut|redux|imax|hdr|sdr|3d|4k|uhd|1080p|720p|2160p|blu-?ray|brrip|bdrip|dvdrip|web-?dl|webrip|hdrip|x264|x265|h\.?264|h\.?265|hevc|dts|aac|ac3)\b",
    )
    .unwrap()
});
static RSS_TITLE_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"<letterboxd:filmTitle>(.*?)</letterboxd:filmTitle>").unwrap());
static RSS_YEAR_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"<letterboxd:filmYear>(\d{4})</letterboxd:filmYear>").unwrap());
static RSS_RATING_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"<letterboxd:memberRating>([0-9.]+)</letterboxd:memberRating>").unwrap()
});
static RSS_LIKE_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"<letterboxd:memberLike>(\w+)</letterboxd:memberLike>").unwrap());

// --- data model -----------------------------------------------------------

/// One configured account, as surfaced to clients (name + its dot color).
#[derive(Debug, Clone, Serialize)]
pub struct Account {
    pub name: String,
    pub color: String,
}

/// One account's relationship to a film. `rating` is half-stars 1..=10 (so a
/// display value of `rating / 2` gives 0.5..=5.0); `None` means watched-unrated.
#[derive(Debug, Clone)]
struct Watch {
    account: usize,
    rating: Option<u8>,
    liked: bool,
}

/// The aggregate status of one film across every configured account.
#[derive(Debug, Default, Clone)]
struct FilmStatus {
    watched: Vec<Watch>,
    /// Account indices that have this film on their watchlist.
    watchlist: Vec<usize>,
}

/// The immutable, snapshot-style overlay. Built by [`harvest`], swapped in
/// atomically. Reads (`annotate`) are lock-free.
#[derive(Debug, Default)]
pub struct Overlay {
    pub accounts: Vec<Account>,
    films: HashMap<FilmKey, FilmStatus>,
    /// normalized-title (year dropped) → the keys sharing it, so a disk entry
    /// whose name lacks a `(YYYY)` can still match when the title is unique.
    by_title: HashMap<String, Vec<FilmKey>>,
    /// year → keys released that year, so the prefix tier only compares films of
    /// the same year (bounds the search and doubles as the year guard).
    by_year: HashMap<u16, Vec<FilmKey>>,
    /// Letterboxd slug → key and TMDB id → key, for *exact* sidecar matching
    /// (`annotate_id`). A sidecar's `letterboxd`/`tmdb` beats any title guessing.
    by_slug: HashMap<String, FilmKey>,
    by_tmdb: HashMap<u32, FilmKey>,
    /// A readable `Title (Year)` for each key (first one harvested), used only
    /// by the diagnostic `report`. Match logic never touches it.
    names: HashMap<FilmKey, String>,
}

/// One row of the hit-rate report: a full-outer-join of the disk library and
/// the harvested Letterboxd films. `status` is `both`, `disk_only`, or `lb_only`.
#[derive(Debug)]
pub struct ReportRow {
    pub status: &'static str,
    pub disk_name: String,
    pub letterboxd_name: String,
    pub norm_key: String,
    pub year: String,
    pub watched_by: String,
    pub rating: String,
    pub liked_by: String,
    pub watchlist_by: String,
}

// --- serialized annotation (rides on browse/recent/search entries) ---------

/// The compact per-entry payload attached to a matching library entry. Absent
/// entirely when a disk entry matches no harvested film, so non-movie content
/// (TV, oddly-named files) stays clean and payloads stay lean.
#[derive(Debug, Serialize)]
pub struct Annotation {
    pub watched: Vec<WatchOut>,
    /// Account names with this film on their watchlist.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub watchlist: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct WatchOut {
    pub account: String,
    /// Stars, 0.5..=5.0. Absent when watched-but-unrated.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rating: Option<f32>,
    #[serde(skip_serializing_if = "is_false")]
    pub liked: bool,
}

fn is_false(b: &bool) -> bool {
    !*b
}

impl Overlay {
    /// Correlate one library entry name (a file like `The Matrix (1999).mkv` or
    /// a movie folder like `Blade Runner 2049 (2017)`) to a harvested film.
    pub fn annotate(&self, entry_name: &str) -> Option<Annotation> {
        self.annotation_for(self.lookup(entry_name)?)
    }

    /// Exact match by a sidecar's Letterboxd slug (bare or a full film URL) or
    /// TMDB id — beats any title guessing. `None` when neither id is one the
    /// overlay harvested.
    pub fn annotate_id(&self, slug: Option<&str>, tmdb: Option<u32>) -> Option<Annotation> {
        let key = slug
            .and_then(|s| self.by_slug.get(&normalize_slug(s)))
            .or_else(|| tmdb.and_then(|t| self.by_tmdb.get(&t)))?;
        self.annotation_for(self.films.get(key)?)
    }

    fn annotation_for(&self, status: &FilmStatus) -> Option<Annotation> {
        if status.watched.is_empty() && status.watchlist.is_empty() {
            return None;
        }
        Some(Annotation {
            watched: status
                .watched
                .iter()
                .map(|w| WatchOut {
                    account: self.accounts[w.account].name.clone(),
                    rating: w.rating.map(|r| f32::from(r) / 2.0),
                    liked: w.liked,
                })
                .collect(),
            watchlist: status
                .watchlist
                .iter()
                .map(|&i| self.accounts[i].name.clone())
                .collect(),
        })
    }

    fn lookup(&self, entry_name: &str) -> Option<&FilmStatus> {
        self.films.get(&self.lookup_key(entry_name)?)
    }

    /// The harvested-film key a disk entry name resolves to, or `None`. Same
    /// logic `lookup` uses, but returns the key so callers (the report) can tell
    /// which side of the join matched.
    fn lookup_key(&self, entry_name: &str) -> Option<FilmKey> {
        let (title, year) = parse_name(strip_video_ext(entry_name));
        if title.is_empty() {
            return None;
        }
        // 1. Exact (title, year) — the strong match.
        if let Some(y) = year {
            let key = (title.clone(), Some(y));
            if self.films.contains_key(&key) {
                return Some(key);
            }
        }
        // 2. Title index: a unique title wins even when the year is missing or
        //    off by one (release vs. premiere).
        if let Some(keys) = self.by_title.get(&title) {
            if keys.len() == 1 {
                return Some(keys[0].clone());
            }
            if let Some(y) = year {
                for k in keys {
                    if matches!(k.1, Some(ky) if ky.abs_diff(y) <= 1) {
                        return Some(k.clone());
                    }
                }
            }
        }
        // 3. Prefix tier: a short disk title that is a prefix of one same-year
        //    canonical title (or vice-versa), and *only* one — catches `Birdman`
        //    ⟷ `Birdman or (The Unexpected Virtue of Ignorance)`. The exact-year
        //    match, the single-candidate rule, and the ≥5-char floor on both
        //    sides keep false positives near zero.
        if title.len() >= 5 {
            if let Some(y) = year {
                if let Some(cands) = self.by_year.get(&y) {
                    let hits: Vec<&FilmKey> = cands
                        .iter()
                        .filter(|k| {
                            k.0 != title
                                && k.0.len() >= 5
                                && (k.0.starts_with(&title) || title.starts_with(k.0.as_str()))
                        })
                        .collect();
                    if hits.len() == 1 {
                        return Some(hits[0].clone());
                    }
                }
            }
        }
        None
    }

    /// Build the full-outer-join hit-rate report over a set of disk entry names.
    /// Every disk name becomes a `both` row (if it resolves to a harvested film)
    /// or a `disk_only` row; every harvested film that no disk name matched
    /// becomes an `lb_only` row. Sorted by the normalized key so alphabetically
    /// adjacent titles — and thus likely near-misses — sit together.
    pub fn report(&self, disk_names: &[String]) -> Vec<ReportRow> {
        use std::collections::HashSet;
        let mut rows = Vec::new();
        let mut matched: HashSet<FilmKey> = HashSet::new();
        for name in disk_names {
            if let Some(key) = self.lookup_key(name) {
                matched.insert(key.clone());
                let status = &self.films[&key];
                rows.push(self.row("both", name.clone(), &key, status));
            } else {
                let (title, year) = parse_name(strip_video_ext(name));
                rows.push(ReportRow {
                    status: "disk_only",
                    disk_name: name.clone(),
                    letterboxd_name: String::new(),
                    norm_key: title,
                    year: year.map(|v| v.to_string()).unwrap_or_default(),
                    watched_by: String::new(),
                    rating: String::new(),
                    liked_by: String::new(),
                    watchlist_by: String::new(),
                });
            }
        }
        for (key, status) in &self.films {
            if !matched.contains(key) {
                rows.push(self.row("lb_only", String::new(), key, status));
            }
        }
        rows.sort_by(|a, b| {
            a.norm_key
                .cmp(&b.norm_key)
                .then(a.year.cmp(&b.year))
                .then(a.disk_name.cmp(&b.disk_name))
        });
        rows
    }

    fn row(
        &self,
        status: &'static str,
        disk_name: String,
        key: &FilmKey,
        st: &FilmStatus,
    ) -> ReportRow {
        let join = |names: Vec<String>| names.join(",");
        let acct = |i: usize| self.accounts[i].name.clone();
        ReportRow {
            status,
            disk_name,
            letterboxd_name: self.names.get(key).cloned().unwrap_or_default(),
            norm_key: key.0.clone(),
            year: key.1.map(|v| v.to_string()).unwrap_or_default(),
            watched_by: join(st.watched.iter().map(|w| acct(w.account)).collect()),
            rating: join(
                st.watched
                    .iter()
                    .filter_map(|w| {
                        w.rating
                            .map(|r| format!("{}={}", acct(w.account), f32::from(r) / 2.0))
                    })
                    .collect(),
            ),
            liked_by: join(
                st.watched
                    .iter()
                    .filter(|w| w.liked)
                    .map(|w| acct(w.account))
                    .collect(),
            ),
            watchlist_by: join(st.watchlist.iter().map(|&i| acct(i)).collect()),
        }
    }
}

// --- the harvester handle -------------------------------------------------

/// Cheap-to-clone handle holding the current overlay and the machinery to
/// rebuild it. Reads go through `overlay()`; `refresh()` kicks a rebuild.
#[derive(Clone)]
pub struct Letterboxd {
    accounts: Arc<Vec<String>>,
    overlay: Arc<ArcSwap<Overlay>>,
    /// Coalesces overlapping refreshes: a harvest takes a minute or two, so a
    /// mashed Refresh button folds into the in-flight one instead of stacking.
    refreshing: Arc<AtomicBool>,
}

impl Letterboxd {
    /// Build a handle for the configured accounts. The initial overlay is empty
    /// but already carries the account list + colors, so `/api/letterboxd/
    /// accounts` works before the first harvest completes.
    pub fn new(accounts: Vec<String>) -> Self {
        let overlay = Overlay {
            accounts: account_list(&accounts),
            ..Overlay::default()
        };
        Self {
            accounts: Arc::new(accounts),
            overlay: Arc::new(ArcSwap::from_pointee(overlay)),
            refreshing: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn is_configured(&self) -> bool {
        !self.accounts.is_empty()
    }

    /// Atomically read the current overlay.
    pub fn overlay(&self) -> Arc<Overlay> {
        self.overlay.load_full()
    }

    /// Kick a background harvest, unless one is already running (in which case
    /// this is a no-op — the running harvest will pick up any state). The
    /// overlay is only replaced on a successful build, so a Cloudflare hiccup
    /// mid-harvest leaves the previous good data in place.
    pub fn refresh(&self) {
        if !self.is_configured() {
            return;
        }
        if self.refreshing.swap(true, Ordering::SeqCst) {
            tracing::debug!("letterboxd refresh already in progress; coalescing");
            return;
        }
        let accounts = self.accounts.clone();
        let overlay = self.overlay.clone();
        let refreshing = self.refreshing.clone();
        tokio::task::spawn_blocking(move || {
            tracing::info!(accounts = accounts.len(), "letterboxd harvest starting");
            let built = harvest(&accounts);
            let films = built.films.len();
            overlay.store(Arc::new(built));
            refreshing.store(false, Ordering::SeqCst);
            tracing::info!(films, "letterboxd harvest complete");
        });
    }
}

fn account_list(accounts: &[String]) -> Vec<Account> {
    accounts
        .iter()
        .enumerate()
        .map(|(i, name)| Account {
            name: name.clone(),
            color: PALETTE[i % PALETTE.len()].to_string(),
        })
        .collect()
}

// --- the harvest ----------------------------------------------------------

/// One account's harvested relationships, keyed by film, prior to merging.
#[derive(Default)]
struct AccountData {
    /// key → (rating half-stars, liked)
    watched: HashMap<FilmKey, (Option<u8>, bool)>,
    watchlist: Vec<FilmKey>,
    /// key → readable `Title (Year)` as seen on Letterboxd (for the report).
    names: HashMap<FilmKey, String>,
    /// Letterboxd slug → key, and TMDB id → key, for exact sidecar matching.
    slugs: HashMap<String, FilmKey>,
    tmdbs: HashMap<u32, FilmKey>,
}

/// Build a fresh overlay for every account. Blocking + network-bound; always
/// called from `spawn_blocking`.
fn harvest(accounts: &[String]) -> Overlay {
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(25))
        .user_agent(USER_AGENT)
        .build();

    let mut films: HashMap<FilmKey, FilmStatus> = HashMap::new();
    let mut names: HashMap<FilmKey, String> = HashMap::new();
    let mut by_slug: HashMap<String, FilmKey> = HashMap::new();
    let mut by_tmdb: HashMap<u32, FilmKey> = HashMap::new();
    for (i, user) in accounts.iter().enumerate() {
        let data = harvest_account(&agent, user);
        tracing::info!(
            account = user.as_str(),
            watched = data.watched.len(),
            watchlist = data.watchlist.len(),
            slugs = data.slugs.len(),
            "letterboxd account harvested"
        );
        for (key, (rating, liked)) in data.watched {
            films.entry(key).or_default().watched.push(Watch {
                account: i,
                rating,
                liked,
            });
        }
        for key in data.watchlist {
            let status = films.entry(key).or_default();
            if !status.watchlist.contains(&i) {
                status.watchlist.push(i);
            }
        }
        for (key, name) in data.names {
            names.entry(key).or_insert(name);
        }
        for (slug, key) in data.slugs {
            by_slug.entry(slug).or_insert(key);
        }
        for (tmdb, key) in data.tmdbs {
            by_tmdb.entry(tmdb).or_insert(key);
        }
    }

    let by_title = build_title_index(&films);
    let by_year = build_year_index(&films);
    Overlay {
        accounts: account_list(accounts),
        films,
        by_title,
        by_year,
        by_slug,
        by_tmdb,
        names,
    }
}

/// Lightly un-escape the HTML entities Letterboxd emits in `data-item-name`
/// (e.g. `Hansel &amp; Gretel`) so the report shows a readable title. The match
/// key doesn't use this — it strips entities entirely in `norm_title`.
fn display_name(raw: &str) -> String {
    raw.replace("&amp;", "&")
        .replace("&#39;", "'")
        .replace("&#039;", "'")
        .replace("&quot;", "\"")
        .trim()
        .to_string()
}

fn build_title_index(films: &HashMap<FilmKey, FilmStatus>) -> HashMap<String, Vec<FilmKey>> {
    let mut idx: HashMap<String, Vec<FilmKey>> = HashMap::new();
    for key in films.keys() {
        idx.entry(key.0.clone()).or_default().push(key.clone());
    }
    idx
}

fn build_year_index(films: &HashMap<FilmKey, FilmStatus>) -> HashMap<u16, Vec<FilmKey>> {
    let mut idx: HashMap<u16, Vec<FilmKey>> = HashMap::new();
    for key in films.keys() {
        if let Some(y) = key.1 {
            idx.entry(y).or_default().push(key.clone());
        }
    }
    idx
}

fn harvest_account(agent: &ureq::Agent, user: &str) -> AccountData {
    let mut data = AccountData::default();

    // Watched set + ratings — the authoritative "watched" list. Page 1 is
    // reliable; deeper pages are the Cloudflare-gated "full history" tier, so
    // they get the most retry patience (5 tries) and degrade gracefully.
    let films_base = format!("https://letterboxd.com/{user}/films/");
    harvest_grid(
        agent,
        &films_base,
        "/films/page/",
        60,
        5,
        |name, slug, rating| {
            let key = parse_name(name);
            if !key.0.is_empty() {
                data.names
                    .entry(key.clone())
                    .or_insert_with(|| display_name(name));
                if let Some(slug) = slug {
                    data.slugs
                        .entry(slug.to_string())
                        .or_insert_with(|| key.clone());
                }
                let e = data.watched.entry(key).or_insert((None, false));
                if rating.is_some() {
                    e.0 = rating;
                }
            }
        },
    );

    // RSS — the reliable source of hearts (and a rating fallback), plus the
    // TMDB id that lets a sidecar match a film exactly.
    polite_pause();
    if let Some(rss) = fetch(agent, &format!("https://letterboxd.com/{user}/rss/"), 3) {
        for (key, rating, liked, tmdb) in parse_rss(&rss) {
            if key.0.is_empty() {
                continue;
            }
            if let Some(t) = tmdb {
                data.tmdbs.entry(t).or_insert_with(|| key.clone());
            }
            let e = data.watched.entry(key).or_insert((None, false));
            if liked {
                e.1 = true;
            }
            if e.0.is_none() {
                e.0 = rating;
            }
        }
    }

    // Full liked set — best-effort (Cloudflare challenges this path); any films
    // it yields get their heart set, but a failure is fine (RSS covered recent).
    polite_pause();
    harvest_grid(
        agent,
        &format!("https://letterboxd.com/{user}/likes/films/"),
        "/likes/films/page/",
        30,
        2,
        |name, slug, _rating| {
            let key = parse_name(name);
            if !key.0.is_empty() {
                data.names
                    .entry(key.clone())
                    .or_insert_with(|| display_name(name));
                if let Some(slug) = slug {
                    data.slugs
                        .entry(slug.to_string())
                        .or_insert_with(|| key.clone());
                }
                data.watched.entry(key).or_insert((None, false)).1 = true;
            }
        },
    );

    // Watchlist.
    polite_pause();
    harvest_grid(
        agent,
        &format!("https://letterboxd.com/{user}/watchlist/"),
        "/watchlist/page/",
        60,
        5,
        |name, slug, _rating| {
            let key = parse_name(name);
            if !key.0.is_empty() {
                data.names
                    .entry(key.clone())
                    .or_insert_with(|| display_name(name));
                if let Some(slug) = slug {
                    data.slugs
                        .entry(slug.to_string())
                        .or_insert_with(|| key.clone());
                }
                data.watchlist.push(key);
            }
        },
    );

    data
}

/// Retries for a *deep* (page 2+) grid page before giving up on the whole tail.
/// Kept small on purpose — see the bail-early note in [`harvest_grid`].
const DEEP_PAGE_TRIES: u32 = 3;

/// Fetch a paginated Letterboxd poster grid (`{base}` for page 1, then
/// `{base}page/2/`, …), parse each film out of it, and hand `(name, rating)` to
/// `sink`. `page_marker` is the substring used to read the max page number from
/// page 1's pagination (e.g. `/films/page/`). `page_cap` bounds runaway loops.
/// `tries` is the retry budget for page 1 (the reliable tier).
fn harvest_grid(
    agent: &ureq::Agent,
    base: &str,
    page_marker: &str,
    page_cap: u32,
    tries: u32,
    mut sink: impl FnMut(&str, Option<&str>, Option<u8>),
) {
    let Some(page1) = fetch(agent, base, tries) else {
        return;
    };
    for (name, slug, rating) in parse_grid(&page1) {
        sink(&name, slug.as_deref(), rating);
    }
    // Deep pages are the Cloudflare-gated "full history" tier. Attempt them, but
    // bail the instant one is challenged past its (small) retry budget: if page
    // 2 is blocked, pages 3..N are too, so grinding through them only hammers
    // Cloudflare and risks escalating a soft challenge into a hard block. Take
    // what a calm host offers; quietly stop otherwise.
    let max = max_page(&page1, page_marker).min(page_cap);
    for p in 2..=max {
        polite_pause();
        let url = format!("{base}page/{p}/");
        let Some(html) = fetch(agent, &url, DEEP_PAGE_TRIES) else {
            tracing::info!(
                base,
                from_page = p,
                "letterboxd deep pages challenged; stopping early"
            );
            break;
        };
        for (name, slug, rating) in parse_grid(&html) {
            sink(&name, slug.as_deref(), rating);
        }
    }
}

/// GET `url`, retrying on transport errors and Cloudflare "Just a moment"
/// challenges. Backoff is deliberately long and jittered: Letterboxd's
/// pagination endpoints are challenged *intermittently* (~half the time), and a
/// burst of fast retries only escalates the challenge — patient, well-spaced
/// tries are what actually let a page through. Returns the first clean body, or
/// `None` after exhausting `tries`.
fn fetch(agent: &ureq::Agent, url: &str, tries: u32) -> Option<String> {
    for attempt in 1..=tries {
        if let Ok(resp) = agent.get(url).call() {
            if let Ok(body) = resp.into_string() {
                if !body.contains("Just a moment") {
                    return Some(body);
                }
            }
        }
        if attempt < tries {
            // 3s, 5s, 7s, … plus up to ~1.5s of jitter.
            std::thread::sleep(jitter(1000 + 2000 * u64::from(attempt), 1500));
        }
    }
    tracing::warn!(
        url,
        tries,
        "letterboxd fetch failed (cloudflare challenge?)"
    );
    None
}

/// A spacer between requests so a full harvest is a gentle, human-paced trickle
/// rather than a burst — the single biggest thing that keeps Cloudflare calm.
fn polite_pause() {
    std::thread::sleep(jitter(2500, 1500));
}

/// `base` ms plus a pseudo-random `0..spread` ms, seeded off the wall clock so
/// requests never fall on a perfectly robotic cadence. Good enough for spacing;
/// not worth pulling in an RNG crate.
fn jitter(base: u64, spread: u64) -> Duration {
    let n = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| u64::from(d.subsec_nanos()))
        .unwrap_or(0);
    Duration::from_millis(base + if spread == 0 { 0 } else { n % spread })
}

// --- parsing --------------------------------------------------------------

/// Parse one poster grid into `(item-name, slug, rating half-stars)` per film.
/// Each film is a `<li class="griditem">` carrying `data-item-name` +
/// `data-item-slug`; its rating, when present, is a `rated-N` span *inside the
/// same item*, so we bound each film's slice to the span between consecutive
/// `data-item-name` matches and read the slug + rating out of that slice.
fn parse_grid(html: &str) -> Vec<(String, Option<String>, Option<u8>)> {
    let names: Vec<(usize, usize, String)> = ITEM_NAME_RE
        .captures_iter(html)
        .map(|c| {
            let whole = c.get(0).unwrap();
            (whole.start(), whole.end(), c[1].to_string())
        })
        .collect();
    let mut out = Vec::with_capacity(names.len());
    for (i, (_, end, name)) in names.iter().enumerate() {
        let slice_end = names.get(i + 1).map_or(html.len(), |n| n.0);
        let slice = &html[*end..slice_end];
        let slug = ITEM_SLUG_RE.captures(slice).map(|c| c[1].to_string());
        let rating = RATED_RE
            .captures(slice)
            .and_then(|c| c[1].parse::<u8>().ok())
            .filter(|n| (1..=10).contains(n));
        out.push((name.clone(), slug, rating));
    }
    out
}

/// Parse the RSS diary feed into `(key, rating half-stars, liked, tmdb id)`.
fn parse_rss(xml: &str) -> Vec<(FilmKey, Option<u8>, bool, Option<u32>)> {
    let mut out = Vec::new();
    for item in xml.split("<item>").skip(1) {
        let Some(title) = RSS_TITLE_RE.captures(item).map(|c| c[1].to_string()) else {
            continue;
        };
        let year = RSS_YEAR_RE
            .captures(item)
            .and_then(|c| c[1].parse::<u16>().ok());
        let rating = RSS_RATING_RE
            .captures(item)
            .and_then(|c| c[1].parse::<f32>().ok())
            .map(|stars| (stars * 2.0).round() as u8)
            .filter(|n| (1..=10).contains(n));
        let liked = RSS_LIKE_RE
            .captures(item)
            .is_some_and(|c| c[1].eq_ignore_ascii_case("yes"));
        let tmdb = RSS_TMDB_RE
            .captures(item)
            .and_then(|c| c[1].parse::<u32>().ok());
        out.push(((norm_title(&title), year), rating, liked, tmdb));
    }
    out
}

/// The largest page number referenced in a paginated grid's markup, e.g. `11`
/// from `…/films/page/11/`. `1` when there's no pagination (single page).
fn max_page(html: &str, marker: &str) -> u32 {
    let mut max = 1;
    let mut rest = html;
    while let Some(pos) = rest.find(marker) {
        rest = &rest[pos + marker.len()..];
        let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
        if let Ok(n) = digits.parse::<u32>() {
            max = max.max(n);
        }
    }
    max
}

/// Split a name like `Blade Runner 2049 (2017)` into `(normalized-title, year)`.
/// The trailing `(YYYY)` is the year; the `2049` stays in the title. A name with
/// no parenthetical year yields `(normalized-title, None)`.
fn parse_name(name: &str) -> FilmKey {
    if let Some(c) = YEAR_RE.captures(name) {
        let year = c[2].parse::<u16>().ok();
        (norm_title(&c[1]), year)
    } else {
        (norm_title(name), None)
    }
}

/// Reduce a title to a stable match key. In order: strip HTML entities; turn
/// `&`/`+` into `and` (so a disk `Hansel and Gretel` meets Letterboxd's `Hansel
/// & Gretel`); drop edition/scene tags (`UNRATED`, `1080p`, …); fold accents to
/// ASCII via NFD decomposition (`Sirât` → `sirat`, `Amélie` → `amelie`); then
/// keep only lowercased ASCII alphanumerics. `(500) Days of Summer` and `500
/// Days of Summer` both become `500daysofsummer`.
fn norm_title(s: &str) -> String {
    // Decode the ampersand entity to a literal "&" first, so it takes the "and"
    // path below — ENTITY_RE would otherwise delete "&amp;" wholesale, making
    // `Hansel &amp; Gretel` diverge from a literal `Hansel & Gretel`.
    let decoded = s.replace("&amp;", "&");
    let no_entities = ENTITY_RE.replace_all(&decoded, "");
    let ampersands = no_entities.replace(['&', '+'], " and ");
    let cleaned = EDITION_RE.replace_all(&ampersands, " ");
    let mut out = String::new();
    for c in cleaned.nfd() {
        match c {
            // A few Latin letters NFD can't decompose — fold them by hand so
            // `Blåhaj`/`Blahaj` etc. still meet.
            'ø' | 'Ø' => out.push('o'),
            'æ' | 'Æ' => out.push_str("ae"),
            'œ' | 'Œ' => out.push_str("oe"),
            'ł' | 'Ł' => out.push('l'),
            'ð' | 'Ð' | 'đ' | 'Đ' => out.push('d'),
            'þ' | 'Þ' => out.push_str("th"),
            'ß' => out.push_str("ss"),
            // NFD turned `é` into `e` + a combining mark; the mark isn't ASCII
            // alphanumeric so it drops here, leaving the bare `e`.
            c if c.is_ascii_alphanumeric() => out.extend(c.to_lowercase()),
            _ => {}
        }
    }
    out
}

/// Extract a Letterboxd slug from either a bare slug or a full film URL,
/// lowercased. `https://letterboxd.com/film/birdman/` → `birdman`; `Birdman` →
/// `birdman`. Matches how slugs are keyed in `by_slug`.
fn normalize_slug(s: &str) -> String {
    s.trim()
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("")
        .to_lowercase()
}

/// Drop a trailing recognised video extension (`.mkv`, `.mp4`, …) so a movie
/// *file* name parses the same as the movie *folder* name would.
fn strip_video_ext(name: &str) -> &str {
    if let Some(dot) = name.rfind('.') {
        let ext = name[dot + 1..].to_ascii_lowercase();
        if VIDEO_EXTS.contains(&ext.as_str()) {
            return &name[..dot];
        }
    }
    name
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn norm_collapses_punctuation_case_ampersand_edition_accents() {
        assert_eq!(norm_title("(500) Days of Summer"), "500daysofsummer");
        assert_eq!(norm_title("500 Days of Summer"), "500daysofsummer");
        // & / + become "and" so a disk "and" spelling meets Letterboxd's "&".
        assert_eq!(norm_title("Hansel & Gretel"), "hanselandgretel");
        assert_eq!(norm_title("Hansel and Gretel"), "hanselandgretel");
        assert_eq!(norm_title("Hansel &amp; Gretel"), "hanselandgretel");
        // Edition / scene tags dropped.
        assert_eq!(
            norm_title("Hansel and Gretel Witch Hunters UNRATED"),
            "hanselandgretelwitchhunters"
        );
        assert_eq!(norm_title("The Movie 1080p BluRay x264"), "themovie");
        // Accents folded to ASCII so they meet plain-ASCII disk names.
        assert_eq!(norm_title("Sirât"), "sirat");
        assert_eq!(norm_title("Amélie"), "amelie");
        assert_eq!(norm_title("Amelie"), "amelie");
    }

    #[test]
    fn parse_name_splits_year_keeping_title_numbers() {
        assert_eq!(
            parse_name("Blade Runner 2049 (2017)"),
            ("bladerunner2049".to_string(), Some(2017))
        );
        assert_eq!(
            parse_name("12 Monkeys (1995)"),
            ("12monkeys".to_string(), Some(1995))
        );
        assert_eq!(parse_name("Airheads"), ("airheads".to_string(), None));
    }

    #[test]
    fn strip_ext_only_strips_video() {
        assert_eq!(
            strip_video_ext("The Matrix (1999).mkv"),
            "The Matrix (1999)"
        );
        assert_eq!(strip_video_ext("300 (2006)"), "300 (2006)");
    }

    #[test]
    fn parse_grid_associates_rating_to_its_own_film() {
        let html = r#"
          <li class="griditem"><div data-item-name="Alpha (2001)"></div>
            <span class="rating rated-8">★★★★</span></li>
          <li class="griditem"><div data-item-name="Beta (2002)"></div></li>
          <li class="griditem"><div data-item-name="Gamma (2003)"></div>
            <span class="rating rated-3">★½</span></li>
        "#;
        let got = parse_grid(html);
        assert_eq!(
            got,
            vec![
                ("Alpha (2001)".to_string(), None, Some(8)),
                ("Beta (2002)".to_string(), None, None),
                ("Gamma (2003)".to_string(), None, Some(3)),
            ]
        );
    }

    #[test]
    fn parse_grid_captures_slug() {
        let html = r#"<li class="griditem"><div data-item-name="Birdman (2014)"
            data-item-slug="birdman"></div>
            <span class="rating rated-8"></span></li>"#;
        assert_eq!(
            parse_grid(html),
            vec![(
                "Birdman (2014)".to_string(),
                Some("birdman".to_string()),
                Some(8)
            )]
        );
    }

    #[test]
    fn normalize_slug_handles_url_and_bare() {
        assert_eq!(
            normalize_slug("https://letterboxd.com/film/birdman/"),
            "birdman"
        );
        assert_eq!(normalize_slug("Birdman"), "birdman");
        assert_eq!(normalize_slug("  birdman  "), "birdman");
    }

    #[test]
    fn max_page_reads_highest() {
        let html = "a /films/page/2/ b /films/page/11/ c /films/page/3/";
        assert_eq!(max_page(html, "/films/page/"), 11);
        assert_eq!(max_page("no pages here", "/films/page/"), 1);
    }

    #[test]
    fn lookup_matches_by_title_year_with_fallbacks() {
        let mut films: HashMap<FilmKey, FilmStatus> = HashMap::new();
        films.insert(
            ("thematrix".to_string(), Some(1999)),
            FilmStatus {
                watched: vec![Watch {
                    account: 0,
                    rating: Some(9),
                    liked: true,
                }],
                watchlist: vec![],
            },
        );
        let overlay = Overlay {
            accounts: vec![Account {
                name: "joe".to_string(),
                color: "#fff".to_string(),
            }],
            by_title: build_title_index(&films),
            by_year: build_year_index(&films),
            films,
            ..Default::default()
        };

        // Exact file match, extension stripped.
        let a = overlay.annotate("The Matrix (1999).mkv").unwrap();
        assert_eq!(a.watched[0].account, "joe");
        assert_eq!(a.watched[0].rating, Some(4.5));
        assert!(a.watched[0].liked);

        // Year off by one still resolves via the unique title.
        assert!(overlay.annotate("The Matrix (2000).mp4").is_some());
        // Year-less, still unique.
        assert!(overlay.annotate("The Matrix").is_some());
        // No such film.
        assert!(overlay.annotate("Dune (2021).mkv").is_none());
    }

    #[test]
    fn prefix_tier_matches_short_disk_title_to_canonical() {
        let mut films: HashMap<FilmKey, FilmStatus> = HashMap::new();
        films.insert(
            (
                "birdmanortheunexpectedvirtueofignorance".to_string(),
                Some(2014),
            ),
            FilmStatus {
                watched: vec![Watch {
                    account: 0,
                    rating: Some(8),
                    liked: false,
                }],
                watchlist: vec![],
            },
        );
        let overlay = Overlay {
            accounts: vec![Account {
                name: "joe".to_string(),
                color: "#fff".to_string(),
            }],
            by_title: build_title_index(&films),
            by_year: build_year_index(&films),
            films,
            ..Default::default()
        };
        // Short disk title is a prefix of the canonical, same year → match.
        assert!(overlay.annotate("Birdman (2014).mp4").is_some());
        // Wrong year → the year guard rejects it.
        assert!(overlay.annotate("Birdman (2010).mp4").is_none());
        // Under the 5-char floor → skipped, stays unmatched.
        assert!(overlay.annotate("Bird (2014).mp4").is_none());
    }

    #[test]
    fn annotate_id_exact_match_by_slug_and_tmdb() {
        let key = (
            "birdmanortheunexpectedvirtueofignorance".to_string(),
            Some(2014),
        );
        let mut films: HashMap<FilmKey, FilmStatus> = HashMap::new();
        films.insert(
            key.clone(),
            FilmStatus {
                watched: vec![Watch {
                    account: 0,
                    rating: Some(8),
                    liked: true,
                }],
                watchlist: vec![],
            },
        );
        let mut by_slug = HashMap::new();
        by_slug.insert("birdman".to_string(), key.clone());
        let mut by_tmdb = HashMap::new();
        by_tmdb.insert(194_662_u32, key.clone());
        let overlay = Overlay {
            accounts: vec![Account {
                name: "joe".to_string(),
                color: "#fff".to_string(),
            }],
            films,
            by_slug,
            by_tmdb,
            ..Default::default()
        };

        // Exact by slug (bare) and by full film URL.
        assert!(overlay.annotate_id(Some("birdman"), None).is_some());
        assert!(overlay
            .annotate_id(Some("https://letterboxd.com/film/birdman/"), None)
            .is_some());
        // Exact by TMDB id.
        let a = overlay.annotate_id(None, Some(194_662)).unwrap();
        assert_eq!(a.watched[0].rating, Some(4.0));
        assert!(a.watched[0].liked);
        // Unknown ids → no match.
        assert!(overlay.annotate_id(Some("nope"), Some(1)).is_none());
    }
}
