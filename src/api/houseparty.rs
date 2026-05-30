//! `/api/houseparty` — a single, shared "fake player" that lets multiple
//! clients watch in sync ("House Party" mode).
//!
//! The server plays nothing. It just holds the party's truth — which vpath is
//! "playing", its duration, the position, and whether it's playing or paused —
//! and advances the position off a wall-clock timestamp. Any client can drive
//! the party by POSTing its own playback state (becoming the "DJ"); every joined
//! client polls `GET` once a second and mirrors what it finds.
//!
//! State machine is trivial: `Some(Player)` while something is playing, `None`
//! when idle. A `POST` overrides whatever is there; a `DELETE` forces idle (used
//! when a client backs out of a video — that stops the video for the whole
//! room). The position is recomputed on every `GET` from `last_event`, and once
//! it naturally reaches `duration` the party lazily returns to idle.

use std::sync::{Arc, Mutex};
use std::time::Instant;

use axum::extract::State;
use axum::response::IntoResponse;
use axum::routing::get;
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

use crate::api::AppState;

/// The shared party slot. `None` == idle (nothing playing).
pub type HouseParty = Arc<Mutex<Option<Player>>>;

pub fn new() -> HouseParty {
    Arc::new(Mutex::new(None))
}

/// The fake player's internal state. `position` is the base position captured at
/// `last_event`; the live position is `position + elapsed` while playing.
#[derive(Debug, Clone)]
pub struct Player {
    pub vpath: String,
    pub duration: f64,
    pub position: f64,
    pub playing: bool,
    pub last_event: Instant,
}

pub fn routes() -> Router<AppState> {
    Router::new().route(
        "/api/houseparty",
        get(get_state).post(post_state).delete(clear_state),
    )
}

/// Body of a `POST` — the driving client's current playback state.
#[derive(Debug, Deserialize)]
pub struct PostBody {
    pub vpath: String,
    pub duration: f64,
    pub position: f64,
    pub playing: bool,
}

/// What every `GET`/`POST` returns: the live party state. `active: false` means
/// idle, in which case the other fields are zeroed/null.
#[derive(Debug, Serialize)]
pub struct HousePartyResponse {
    pub active: bool,
    pub vpath: Option<String>,
    pub duration: f64,
    pub position: f64,
    pub playing: bool,
}

impl HousePartyResponse {
    fn idle() -> Self {
        HousePartyResponse {
            active: false,
            vpath: None,
            duration: 0.0,
            position: 0.0,
            playing: false,
        }
    }

    fn active(p: &Player, live_position: f64) -> Self {
        HousePartyResponse {
            active: true,
            vpath: Some(p.vpath.clone()),
            duration: p.duration,
            position: live_position,
            playing: p.playing,
        }
    }
}

/// Compute the live snapshot, idling the slot if the position has naturally run
/// past the duration. Mutates `slot` (may set it to `None`).
fn snapshot(slot: &mut Option<Player>) -> HousePartyResponse {
    if let Some(p) = slot {
        let live = if p.playing {
            p.position + p.last_event.elapsed().as_secs_f64()
        } else {
            p.position
        };
        if p.duration > 0.0 && live >= p.duration {
            // Ran to the end on its own → back to idle.
            *slot = None;
        } else {
            return HousePartyResponse::active(p, live);
        }
    }
    HousePartyResponse::idle()
}

pub async fn get_state(State(state): State<AppState>) -> impl IntoResponse {
    let mut slot = state.houseparty.lock().unwrap();
    Json(snapshot(&mut slot))
}

pub async fn post_state(
    State(state): State<AppState>,
    Json(body): Json<PostBody>,
) -> impl IntoResponse {
    let mut slot = state.houseparty.lock().unwrap();
    *slot = Some(Player {
        vpath: body.vpath,
        duration: body.duration,
        position: body.position.max(0.0),
        playing: body.playing,
        last_event: Instant::now(),
    });
    tracing::debug!(
        vpath = slot.as_ref().map(|p| p.vpath.as_str()).unwrap_or(""),
        position = body.position,
        duration = body.duration,
        playing = body.playing,
        "houseparty post",
    );
    Json(snapshot(&mut slot))
}

pub async fn clear_state(State(state): State<AppState>) -> impl IntoResponse {
    let mut slot = state.houseparty.lock().unwrap();
    *slot = None;
    tracing::debug!("houseparty cleared → idle");
    Json(HousePartyResponse::idle())
}
