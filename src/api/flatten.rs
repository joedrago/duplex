//! `/api/flatten` — given the virtual path of a directory, return the full
//! depth-first, name-sorted list of every video file vpath beneath it.
//!
//! Powers the tvOS "Binge this folder" action: the client takes this ordered
//! list verbatim as a binge queue. Order is exactly the in-memory tree's
//! `BTreeMap` traversal (lexicographic at each level, descending into each
//! subdirectory as it is encountered) — i.e. flattened and alphabetized by
//! vpath, identical to how `/api/browse` and `/api/next` already order things.

use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::get;
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

use crate::api::{vpath, AppState};
use crate::library::{Dir, Node};

pub fn routes() -> Router<AppState> {
    Router::new().route("/api/flatten", get(flatten))
}

#[derive(Debug, Deserialize)]
pub struct FlattenQuery {
    /// Empty or omitted means the virtual root (every library, flattened).
    #[serde(default)]
    pub path: String,
}

#[derive(Debug, Serialize)]
pub struct FlattenResponse {
    /// The normalized directory the walk started from (echoed back).
    pub origin: String,
    /// Every descendant video file, depth-first and name-sorted.
    pub vpaths: Vec<String>,
}

pub async fn flatten(
    State(state): State<AppState>,
    Query(q): Query<FlattenQuery>,
) -> impl IntoResponse {
    let origin = if q.path.is_empty() {
        String::new()
    } else {
        match vpath::normalize(&q.path) {
            Some(v) => v,
            None => return (StatusCode::BAD_REQUEST, "invalid path").into_response(),
        }
    };

    let tree = state.library.snapshot();
    let dir = if origin.is_empty() {
        tree.root_dir()
    } else {
        match tree.lookup(&origin) {
            Some(Node::Dir(d)) => d,
            Some(Node::File(_)) => {
                return (StatusCode::BAD_REQUEST, "path is a file, not a directory")
                    .into_response();
            }
            None => return StatusCode::NOT_FOUND.into_response(),
        }
    };

    let mut vpaths = Vec::new();
    collect(dir, &origin, &mut vpaths);

    Json(FlattenResponse { origin, vpaths }).into_response()
}

/// Depth-first walk: `children` is a `BTreeMap`, so iteration is already
/// name-sorted. Files are emitted in place; directories are descended into as
/// they're reached, producing the flattened-by-vpath order.
fn collect(dir: &Dir, prefix: &str, out: &mut Vec<String>) {
    for (name, node) in &dir.children {
        let child_vpath = if prefix.is_empty() {
            name.clone()
        } else {
            format!("{prefix}/{name}")
        };
        match node {
            Node::File(_) => out.push(child_vpath),
            Node::Dir(sub) => collect(sub, &child_vpath, out),
        }
    }
}
