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
use crate::letterboxd::{Account, Annotation};
use crate::library::{Dir, Library, Node, VIDEO_EXTS};

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
    StatusCode::ACCEPTED
}

#[derive(Deserialize)]
struct DetailsQuery {
    #[serde(default)]
    path: String,
}

/// The optional sidecar JSON that can sit next to a movie + poster
/// (`Birdman (2014).json`). Every field is optional; the two ids give an
/// *exact* Letterboxd match, the rest feed the Details page.
#[derive(Deserialize, Default)]
struct Sidecar {
    /// Letterboxd slug (`birdman`) or full film URL. Exact match.
    letterboxd: Option<String>,
    /// TMDB movie id. Exact match (alternative to `letterboxd`).
    tmdb: Option<u32>,
    title: Option<String>,
    description: Option<String>,
    tagline: Option<String>,
    year: Option<u16>,
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
    let (is_dir, abs_path, own_poster) = match node {
        Node::File(f) => (false, Some(f.abs_path.clone()), f.poster.is_some()),
        Node::Dir(d) => (true, None, d.poster.is_some()),
    };

    // Sidecar JSON (files only): `Movie (Year).json` beside the video.
    let sidecar: Sidecar = abs_path
        .as_ref()
        .map(|p| p.with_extension("json"))
        .filter(|p| p.is_file())
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();

    // Exact match via the sidecar id first; fall back to the title/year matcher.
    let letterboxd = overlay
        .annotate_id(sidecar.letterboxd.as_deref(), sidecar.tmdb)
        .or_else(|| overlay.annotate(&name));

    let (parsed_title, parsed_year) = display_title_year(&name);
    let parent = vpath.rsplit_once('/').map_or("", |(p, _)| p);

    Json(DetailsResponse {
        title: sidecar.title.unwrap_or(parsed_title),
        year: sidecar.year.or(parsed_year),
        poster: own_poster || tree.inherited_dir_poster(parent).is_some(),
        is_dir,
        description: sidecar.description,
        tagline: sidecar.tagline,
        letterboxd,
        vpath,
        name,
    })
    .into_response()
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
