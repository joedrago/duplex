//! `/api/recent` — the N most-recently-modified top-level entries in each
//! library, merged and sorted by mtime. Used by the web client to render a
//! "Recently added" section at the top of the root browse view (#/browse/).
//!
//! Only entries at the immediate root of a library are considered, regardless
//! of kind: a freshly added TV episode buried under `TV/Show/S3/` surfaces as
//! its top-level container `Show` (whose dir mtime bubbles up via the tree's
//! deep-mtime invariant), not as a noisy stream of individual episode files.

use std::time::SystemTime;

use axum::extract::{Query, State};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

use crate::api::AppState;
use crate::library::Node;

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
        /// Whether a sidecar poster image is available via `/api/poster`.
        poster: bool,
    },
}

impl Item {
    fn mtime(&self) -> i64 {
        match self {
            Item::Dir { mtime, .. } | Item::File { mtime, .. } => *mtime,
        }
    }

    fn name(&self) -> &str {
        match self {
            Item::Dir { name, .. } | Item::File { name, .. } => name,
        }
    }
}

pub async fn recent(
    State(state): State<AppState>,
    Query(q): Query<RecentQuery>,
) -> impl IntoResponse {
    let limit = q.limit.clamp(1, 100);
    let tree = state.library.snapshot();

    let mut items: Vec<Item> = Vec::new();
    for (lib_name, lib_node) in &tree.root.children {
        let Node::Dir(lib) = lib_node else { continue };
        for (name, node) in &lib.children {
            let vpath = format!("{lib_name}/{name}");
            match node {
                Node::Dir(d) => items.push(Item::Dir {
                    name: name.clone(),
                    vpath,
                    mtime: epoch_seconds(d.mtime),
                    children: d.children.len(),
                }),
                Node::File(f) => items.push(Item::File {
                    name: name.clone(),
                    vpath,
                    mtime: epoch_seconds(f.mtime),
                    size: f.size,
                    poster: f.poster.is_some(),
                }),
            }
        }
    }
    items.sort_by(|a, b| {
        b.mtime()
            .cmp(&a.mtime())
            .then_with(|| a.name().cmp(b.name()))
    });
    items.truncate(limit);

    Json(RecentResponse { items })
}

fn epoch_seconds(t: SystemTime) -> i64 {
    t.duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}
