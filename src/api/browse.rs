use axum::extract::{Query, State};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

use crate::api::{vpath, AppState};
use crate::capability;
use crate::library::Node;

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
    },
    File {
        name: String,
        ext: Option<String>,
        size: u64,
        decision: Option<String>,
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

    let caps = capability::default_caps();
    let mut entries = Vec::with_capacity(dir.children.len());
    for (name, node) in &dir.children {
        match node {
            Node::Dir(d) => entries.push(Entry::Dir {
                name: name.clone(),
                children: d.children.len(),
            }),
            Node::File(f) => {
                // Cheap quality hint without forcing a probe.
                let codec_hint = state
                    .probe
                    .cached(&f.abs_path, f.size, f.mtime)
                    .and_then(|p| p.video_codec().map(str::to_string));
                let decision = state
                    .probe
                    .cached(&f.abs_path, f.size, f.mtime)
                    .map(|p| capability::decide(&p, &caps).label());
                entries.push(Entry::File {
                    name: name.clone(),
                    ext: f.ext.clone(),
                    size: f.size,
                    decision,
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
