//! `/api/next` — given the virtual path of a currently-playing video file,
//! return the next-alphabetical sibling file in the same directory, if any.
//!
//! Used by the player's "Continue" button shown when a file naturally ends.
//! No state, no preferences, no filter — just the next file by sorted name.

use std::time::SystemTime;

use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::get;
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

use crate::api::{vpath, AppState};
use crate::library::Node;

pub fn routes() -> Router<AppState> {
    Router::new().route("/api/next", get(next))
}

#[derive(Debug, Deserialize)]
pub struct NextQuery {
    pub path: String,
}

#[derive(Debug, Serialize)]
pub struct NextResponse {
    pub name: String,
    pub vpath: String,
    pub mtime: i64,
}

pub async fn next(State(state): State<AppState>, Query(q): Query<NextQuery>) -> impl IntoResponse {
    let Some(norm) = vpath::normalize(&q.path) else {
        return (StatusCode::BAD_REQUEST, "invalid path").into_response();
    };

    // Split into (parent_vpath, leaf). An empty parent means the file is a
    // direct child of the virtual root, which can't happen with our library
    // shape (the root only holds library directories), but handle it cleanly.
    let (parent_vpath, leaf) = match norm.rfind('/') {
        Some(i) => (norm[..i].to_string(), norm[i + 1..].to_string()),
        None => (String::new(), norm.clone()),
    };

    let tree = state.library.snapshot();
    let parent_dir = if parent_vpath.is_empty() {
        tree.root_dir()
    } else {
        match tree.lookup(&parent_vpath) {
            Some(Node::Dir(d)) => d,
            _ => return StatusCode::NOT_FOUND.into_response(),
        }
    };

    // BTreeMap iteration is sorted; walk past the current leaf and pick the
    // next entry that is a file. Directories are skipped — Continue is about
    // "what plays next," not "what to browse next."
    let mut found_self = false;
    for (name, node) in &parent_dir.children {
        if !found_self {
            if name == &leaf {
                found_self = true;
            }
            continue;
        }
        if let Node::File(f) = node {
            let item_vpath = if parent_vpath.is_empty() {
                name.clone()
            } else {
                format!("{parent_vpath}/{name}")
            };
            return Json(NextResponse {
                name: name.clone(),
                vpath: item_vpath,
                mtime: epoch_seconds(f.mtime),
            })
            .into_response();
        }
    }

    StatusCode::NOT_FOUND.into_response()
}

fn epoch_seconds(t: SystemTime) -> i64 {
    t.duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}
