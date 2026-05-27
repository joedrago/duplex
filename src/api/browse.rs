use std::time::SystemTime;

use axum::extract::{Query, State};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

use crate::api::{vpath, AppState};
use crate::library::Node;

fn epoch_seconds(t: SystemTime) -> i64 {
    t.duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

pub fn routes() -> Router<AppState> {
    Router::new().route("/api/browse", get(browse))
}

#[derive(Debug, Deserialize)]
pub struct BrowseQuery {
    /// Empty or omitted means the virtual root.
    #[serde(default)]
    pub path: String,
}

#[derive(Debug, Serialize)]
pub struct BrowseResponse {
    pub path: String,
    pub entries: Vec<Entry>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Entry {
    Dir {
        name: String,
        children: usize,
        /// Unix-epoch seconds. For directories this is the deep mtime —
        /// the maximum mtime of any descendant file — so freshly added
        /// files inside subtrees bubble up.
        mtime: i64,
    },
    File {
        name: String,
        ext: Option<String>,
        size: u64,
        mtime: i64,
        codec_hint: Option<String>,
    },
}

pub async fn browse(
    State(state): State<AppState>,
    Query(q): Query<BrowseQuery>,
) -> impl IntoResponse {
    let vpath_norm = if q.path.is_empty() {
        String::new()
    } else {
        match vpath::normalize(&q.path) {
            Some(v) => v,
            None => {
                return (axum::http::StatusCode::BAD_REQUEST, "invalid path").into_response();
            }
        }
    };

    let tree = state.library.snapshot();
    let dir = if vpath_norm.is_empty() {
        tree.root_dir()
    } else {
        match tree.lookup(&vpath_norm) {
            Some(Node::Dir(d)) => d,
            Some(Node::File(_)) => {
                return (
                    axum::http::StatusCode::BAD_REQUEST,
                    "path is a file, not a directory",
                )
                    .into_response();
            }
            None => {
                return axum::http::StatusCode::NOT_FOUND.into_response();
            }
        }
    };

    let mut entries = Vec::with_capacity(dir.children.len());

    // At the virtual root, emit library roots in CLI order (the order the user
    // passed --library on the command line) rather than the BTreeMap's
    // alphabetical iteration. Deeper directories stay alphabetical.
    let ordered: Vec<(&String, &Node)> = if vpath_norm.is_empty() {
        state
            .library
            .roots
            .iter()
            .filter_map(|r| dir.children.get_key_value(&r.name))
            .collect()
    } else {
        dir.children.iter().collect()
    };

    for (name, node) in ordered {
        match node {
            Node::Dir(d) => entries.push(Entry::Dir {
                name: name.clone(),
                children: d.children.len(),
                mtime: epoch_seconds(d.mtime),
            }),
            Node::File(f) => {
                // Cheap quality hint without forcing a probe.
                let codec_hint = state
                    .probe
                    .cached(&f.abs_path, f.size, f.mtime)
                    .and_then(|p| p.video_codec().map(str::to_string));
                entries.push(Entry::File {
                    name: name.clone(),
                    ext: f.ext.clone(),
                    size: f.size,
                    mtime: epoch_seconds(f.mtime),
                    codec_hint,
                });
            }
        }
    }

    Json(BrowseResponse {
        path: vpath_norm,
        entries,
    })
    .into_response()
}
