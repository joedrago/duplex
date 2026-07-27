//! Letterboxd overlay endpoints.
//!
//! - `GET /api/letterboxd/accounts` — the configured accounts and their dot
//!   colors, so clients can render the per-person legend and the "by person"
//!   filter. Returns an empty list when `--letterboxd` is unset.
//! - `POST /api/refresh` — the server side of the clients' existing **Refresh**
//!   gesture. Kicks a fresh Letterboxd harvest (coalesced if one is already
//!   running) and returns immediately; the overlay updates when the harvest
//!   finishes. There is deliberately no separate Letterboxd-refresh control —
//!   the one Refresh button drives everything.

use axum::extract::{Query, State};
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

use crate::api::{vpath, AppState};
use crate::letterboxd::{Account, Annotation, Overlay};
use crate::library::{scan, Dir, Library, Meta, Node, VIDEO_EXTS};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/letterboxd/accounts", get(accounts))
        .route("/api/letterboxd/report.tsv", get(report_tsv))
        .route("/api/details", get(details))
        .route("/api/refresh", post(refresh))
}

#[derive(Serialize)]
struct AccountsResponse {
    accounts: Vec<Account>,
}

async fn accounts(State(state): State<AppState>) -> Json<AccountsResponse> {
    Json(AccountsResponse {
        accounts: state.letterboxd.overlay().accounts.clone(),
    })
}

async fn refresh(State(state): State<AppState>) -> StatusCode {
    state.letterboxd.refresh();

    // Also re-walk the library. Sidecar JSON is read at scan time, so without
    // this an edited `Movie.json` would never reach a client — and Refresh is
    // the one gesture users have. Blocking I/O over a possibly-networked mount,
    // hence spawn_blocking; the swap is atomic and clients see it on their
    // follow-up browse/recent.
    let lib = state.library.clone();
    tokio::task::spawn_blocking(move || {
        let tree = scan::scan(&lib);
        lib.replace(tree);
        tracing::info!("library rescanned on refresh");
    });

    StatusCode::ACCEPTED
}

#[derive(Deserialize)]
struct DetailsQuery {
    #[serde(default)]
    path: String,
}

#[derive(Serialize)]
struct DetailsResponse {
    vpath: String,
    name: String,
    title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    year: Option<u16>,
    poster: bool,
    is_dir: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tagline: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    letterboxd: Option<Annotation>,
}

/// `GET /api/details?path=…` — everything the Details page needs for one title:
/// display title/year, poster availability, optional sidecar description, and
/// the Letterboxd status (matched *exactly* by a sidecar `letterboxd`/`tmdb`
/// when present, else by the title/year matcher).
async fn details(
    State(state): State<AppState>,
    Query(q): Query<DetailsQuery>,
) -> impl IntoResponse {
    let Some(vpath) = vpath::normalize(&q.path) else {
        return (StatusCode::BAD_REQUEST, "invalid path").into_response();
    };
    let tree = state.library.snapshot();
    let Some(node) = tree.lookup(&vpath) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let overlay = state.letterboxd.overlay();

    let name = vpath.rsplit('/').next().unwrap_or(&vpath).to_string();
    // The sidecar was parsed at scan time and rides on the node — the very same
    // `Meta` that browse/search/recent annotate from, so Details can never
    // disagree with the row the user selected to get here. Movie *folders*
    // carry one too, via the dir-poster naming convention.
    let (is_dir, own_poster, meta) = match node {
        Node::File(f) => (false, f.poster.is_some(), f.meta.as_ref()),
        Node::Dir(d) => (true, d.poster.is_some(), d.meta.as_ref()),
    };

    let (title, year) = effective_title_year(&name, meta);
    let letterboxd = annotate_entry(&overlay, &name, meta);
    let parent = vpath.rsplit_once('/').map_or("", |(p, _)| p);

    Json(DetailsResponse {
        title,
        year,
        poster: own_poster || tree.inherited_dir_poster(parent).is_some(),
        is_dir,
        description: meta.and_then(|m| m.description.clone()),
        tagline: meta.and_then(|m| m.tagline.clone()),
        letterboxd,
        vpath,
        name,
    })
    .into_response()
}

/// The title and year an entry *presents* as: the sidecar JSON's when it
/// supplies them, else parsed from the filename. This is what every client
/// displays, sorts by, and buckets under in the A-Z rail.
///
/// `name` is deliberately untouched by this — it stays the real filename, so
/// vpaths, poster URLs, playback, and focus identity are unaffected by a
/// sidecar. Likewise mtime: `Recently Added` stays keyed to the video file, not
/// to when someone edited its JSON.
pub fn effective_title_year(name: &str, meta: Option<&Meta>) -> (String, Option<u16>) {
    let (parsed_title, parsed_year) = display_title_year(name);
    match meta {
        Some(m) => (
            m.title.clone().unwrap_or(parsed_title),
            m.year.or(parsed_year),
        ),
        None => (parsed_title, parsed_year),
    }
}

/// The title/year to put *on the wire* for a list entry. `Some` only when a
/// sidecar actually has something to say about the entry's identity, so a
/// library with no sidecars serialises exactly the bytes it always did and
/// clients keep their filename derivation as the default path.
///
/// When it does fire, both halves are resolved together — a sidecar that sets
/// only `year` still gets its title filled in from the filename — so the client
/// never has to blend two sources to render one label.
pub fn sidecar_title_year(name: &str, meta: Option<&Meta>) -> (Option<String>, Option<u16>) {
    let Some(m) = meta else {
        return (None, None);
    };
    if m.title.is_none() && m.year.is_none() {
        return (None, None);
    }
    let (title, year) = effective_title_year(name, Some(m));
    (Some(title), year)
}

/// Correlate one entry to a harvested film. A sidecar's `letterboxd`/`tmdb` id
/// is exact and wins outright; failing that, the title/year guesser runs over
/// the *effective* title, so a sidecar that fixes a mangled name also fixes the
/// match without needing an explicit id.
pub fn annotate_entry(overlay: &Overlay, name: &str, meta: Option<&Meta>) -> Option<Annotation> {
    if let Some(m) = meta {
        if let Some(a) = overlay.annotate_id(m.letterboxd.as_deref(), m.tmdb) {
            return Some(a);
        }
        if let Some(title) = &m.title {
            // Feed the guesser a `Title (Year)` shaped probe — the same shape
            // it expects from a filename — so the year still participates.
            let probe = match m.year.or_else(|| display_title_year(name).1) {
                Some(y) => format!("{title} ({y})"),
                None => title.clone(),
            };
            // Falls through to the filename on a miss: a sidecar that renames a
            // film to something Letterboxd doesn't know must never *lose* the
            // match the filename would have found on its own.
            if let Some(a) = overlay.annotate(&probe) {
                return Some(a);
            }
        }
    }
    overlay.annotate(name)
}

/// Split a raw entry name into a display title + year, keeping original casing.
/// `Birdman (2014).mp4` → (`Birdman`, `Some(2014)`).
fn display_title_year(name: &str) -> (String, Option<u16>) {
    let stem = match name.rsplit_once('.') {
        Some((base, ext)) if VIDEO_EXTS.contains(&ext.to_ascii_lowercase().as_str()) => base,
        _ => name,
    };
    let trimmed = stem.trim();
    if let Some(open) = trimmed.rfind('(') {
        if let Some(rel_close) = trimmed[open..].find(')') {
            let inside = &trimmed[open + 1..open + rel_close];
            if inside.len() == 4 && inside.bytes().all(|b| b.is_ascii_digit()) {
                if let Ok(y) = inside.parse::<u16>() {
                    return (trimmed[..open].trim().to_string(), Some(y));
                }
            }
        }
    }
    (trimmed.to_string(), None)
}

/// A tab-separated hit-rate report: the full-outer-join of the disk library and
/// the harvested Letterboxd films, one row per title. Handy for eyeballing match
/// quality in a spreadsheet (`curl … > report.tsv`). Uses the exact same matcher
/// the overlay uses, so what you see here is what the UI would light up.
async fn report_tsv(State(state): State<AppState>) -> impl IntoResponse {
    let overlay = state.letterboxd.overlay();
    let tree = state.library.snapshot();

    let mut disk_names = Vec::new();
    collect_disk_names(&tree.root, &state.library, true, &mut disk_names);
    disk_names.sort();
    disk_names.dedup();

    let mut out = String::from(
        "status\tdisk_name\tletterboxd_name\tnorm_key\tyear\twatched_by\trating\tliked_by\twatchlist_by\n",
    );
    for r in overlay.report(&disk_names) {
        out.push_str(&format!(
            "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n",
            r.status,
            r.disk_name,
            r.letterboxd_name,
            r.norm_key,
            r.year,
            r.watched_by,
            r.rating,
            r.liked_by,
            r.watchlist_by,
        ));
    }

    (
        [(
            header::CONTENT_TYPE,
            "text/tab-separated-values; charset=utf-8",
        )],
        out,
    )
}

/// Collect every movie-ish disk entry name for the report: files at any depth,
/// plus sub-directory names (movie folders), but not the library-root names
/// themselves. Hidden roots are skipped.
fn collect_disk_names(dir: &Dir, lib: &Library, is_root: bool, out: &mut Vec<String>) {
    for (name, node) in &dir.children {
        if is_root && lib.is_hidden_root(name) {
            continue;
        }
        match node {
            Node::File(_) => out.push(name.clone()),
            Node::Dir(d) => {
                // Push movie-folder names, but not the top-level library names.
                if !is_root {
                    out.push(name.clone());
                }
                collect_disk_names(d, lib, false, out);
            }
        }
    }
}
