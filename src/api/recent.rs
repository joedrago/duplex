//! `/api/recent` — the N most-recently-modified files across all library
//! roots. Used by the web client to render a "Recently added" section at
//! the top of the root browse view (#/browse/).
//!
//! Files only — directories aggregate their descendants' mtimes via the
//! tree's deep-mtime invariant, but for a "what was just added" feed, the
//! actual file leaves are what the user thinks of as "things."

use std::time::SystemTime;

use axum::extract::{Query, State};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

use crate::api::AppState;
use crate::library::{Dir, Node};

pub fn routes() -> Router<AppState> {
    Router::new().route("/api/recent", get(recent))
}

#[derive(Debug, Deserialize)]
pub struct RecentQuery {
    #[serde(default = "default_limit")]
    pub limit: usize,
}

fn default_limit() -> usize {
    10
}

#[derive(Debug, Serialize)]
pub struct RecentResponse {
    pub items: Vec<Item>,
}

#[derive(Debug, Serialize)]
pub struct Item {
    /// Basename only — display label for the tile.
    pub name: String,
    /// Full virtual path including library root, suitable for the play route.
    pub vpath: String,
    /// Unix-epoch seconds.
    pub mtime: i64,
    pub size: u64,
}

pub async fn recent(
    State(state): State<AppState>,
    Query(q): Query<RecentQuery>,
) -> impl IntoResponse {
    let limit = q.limit.clamp(1, 100);
    let tree = state.library.snapshot();

    // Heap-of-size-N would be O(N log K); the tree is small enough that
    // collect-and-sort is plenty fast and simpler.
    let mut items: Vec<Item> = Vec::new();
    collect_files(&tree.root, "", &mut items);
    items.sort_by(|a, b| b.mtime.cmp(&a.mtime).then_with(|| a.name.cmp(&b.name)));
    items.truncate(limit);

    Json(RecentResponse { items })
}

fn collect_files(dir: &Dir, prefix: &str, out: &mut Vec<Item>) {
    for (name, node) in &dir.children {
        let vpath = if prefix.is_empty() {
            name.clone()
        } else {
            format!("{prefix}/{name}")
        };
        match node {
            Node::File(f) => out.push(Item {
                name: name.clone(),
                vpath,
                mtime: epoch_seconds(f.mtime),
                size: f.size,
            }),
            Node::Dir(d) => collect_files(d, &vpath, out),
        }
    }
}

fn epoch_seconds(t: SystemTime) -> i64 {
    t.duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}
