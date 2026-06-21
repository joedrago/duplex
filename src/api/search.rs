//! `/api/search?q=<query>&limit=N` — case-insensitive substring search over
//! every file and directory in the virtual tree. Returns at most `limit`
//! matches (default 50, max 200), sorted by match-quality heuristics:
//!
//!   1. Exact name match (case-insensitive)
//!   2. Name begins with the query
//!   3. Word boundary in the name begins with the query
//!   4. Substring anywhere in the name
//!
//! Within each tier ties break by name (case-insensitive). Empty `q` returns
//! an empty result set instead of paging the whole tree.

use std::time::SystemTime;

use axum::extract::{Query, State};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

use crate::api::AppState;
use crate::library::{Dir, Library, Node};

pub fn routes() -> Router<AppState> {
    Router::new().route("/api/search", get(search))
}

#[derive(Debug, Deserialize)]
pub struct SearchQuery {
    pub q: String,
    #[serde(default = "default_limit")]
    pub limit: usize,
}

fn default_limit() -> usize {
    50
}

#[derive(Debug, Serialize)]
pub struct SearchResponse {
    pub items: Vec<Item>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Item {
    Dir {
        name: String,
        vpath: String,
        mtime: i64,
        children: usize,
    },
    File {
        name: String,
        vpath: String,
        mtime: i64,
        size: u64,
    },
}

pub async fn search(
    State(state): State<AppState>,
    Query(q): Query<SearchQuery>,
) -> impl IntoResponse {
    let limit = q.limit.clamp(1, 200);
    let needle = q.q.trim().to_lowercase();
    if needle.is_empty() {
        return Json(SearchResponse { items: Vec::new() });
    }

    let tree = state.library.snapshot();
    let mut hits: Vec<(u8, Item)> = Vec::new();
    walk(&tree.root, String::new(), &needle, &state.library, &mut hits);

    // Hidden-library reveal: an exact, case-sensitive match of the raw query
    // against a hidden root's name surfaces that root as a single browseable
    // directory — the only listing it ever appears in. Its contents are never
    // searched; only the whole-name knock opens the door. Ranked 0 so it sorts
    // among the other exact matches.
    let exact = q.q.trim();
    if state.library.is_hidden_root(exact) {
        if let Some(Node::Dir(d)) = tree.root.children.get(exact) {
            hits.push((
                0,
                Item::Dir {
                    name: exact.to_string(),
                    vpath: exact.to_string(),
                    mtime: epoch_seconds(d.mtime),
                    children: d.children.len(),
                },
            ));
        }
    }

    // Sort: lower rank first, then by name case-insensitively.
    hits.sort_by(|a, b| {
        a.0.cmp(&b.0)
            .then_with(|| name(&a.1).to_lowercase().cmp(&name(&b.1).to_lowercase()))
    });

    let items: Vec<Item> = hits.into_iter().take(limit).map(|(_, item)| item).collect();
    Json(SearchResponse { items })
}

fn name(item: &Item) -> &str {
    match item {
        Item::Dir { name, .. } | Item::File { name, .. } => name,
    }
}

fn walk(dir: &Dir, prefix: String, needle: &str, lib: &Library, out: &mut Vec<(u8, Item)>) {
    for (name, node) in &dir.children {
        // Hidden roots are withheld from substring search entirely — the root
        // and its whole subtree. They surface only via the exact-name reveal in
        // `search`. Only a top-level child (empty prefix) can be a root.
        if prefix.is_empty() && lib.is_hidden_root(name) {
            continue;
        }
        let vpath = if prefix.is_empty() {
            name.clone()
        } else {
            format!("{prefix}/{name}")
        };
        if let Some(rank) = match_rank(name, needle) {
            match node {
                Node::Dir(d) => out.push((
                    rank,
                    Item::Dir {
                        name: name.clone(),
                        vpath: vpath.clone(),
                        mtime: epoch_seconds(d.mtime),
                        children: d.children.len(),
                    },
                )),
                Node::File(f) => out.push((
                    rank,
                    Item::File {
                        name: name.clone(),
                        vpath: vpath.clone(),
                        mtime: epoch_seconds(f.mtime),
                        size: f.size,
                    },
                )),
            }
        }
        if let Node::Dir(d) = node {
            walk(d, vpath, needle, lib, out);
        }
    }
}

/// Lower rank = better match. Returns None if the haystack doesn't contain the
/// needle at all.
fn match_rank(haystack: &str, needle: &str) -> Option<u8> {
    let h = haystack.to_lowercase();
    if h == needle {
        return Some(0);
    }
    if h.starts_with(needle) {
        return Some(1);
    }
    // Word boundary: previous char is whitespace, dot, dash, or underscore.
    let mut boundary_hit = false;
    let bytes = h.as_bytes();
    let needle_bytes = needle.as_bytes();
    if bytes.len() >= needle_bytes.len() {
        for i in 0..=(bytes.len() - needle_bytes.len()) {
            if &bytes[i..i + needle_bytes.len()] == needle_bytes {
                if i == 0 {
                    return Some(1);
                }
                let prev = bytes[i - 1];
                if matches!(prev, b' ' | b'.' | b'-' | b'_' | b'(' | b'[') {
                    boundary_hit = true;
                    break;
                }
            }
        }
    }
    if boundary_hit {
        return Some(2);
    }
    if h.contains(needle) {
        return Some(3);
    }
    None
}

fn epoch_seconds(t: SystemTime) -> i64 {
    t.duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}
