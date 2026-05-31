use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use notify::RecursiveMode;
use notify_debouncer_full::new_debouncer;

use crate::library::{scan, Library};

/// Start a notify-debouncer-full watcher on every configured root. Filesystem
/// events are applied to the library's in-memory tree by cloning + swapping.
///
/// Runs on a dedicated OS thread (the debouncer is synchronous); returns
/// immediately. The watcher lives for the lifetime of the process.
pub fn spawn(lib: Library, debounce_ms: u64) -> Result<()> {
    let probe_invalidator = lib.clone();
    std::thread::Builder::new()
        .name("duplex-watcher".into())
        .spawn(move || {
            if let Err(e) = run(probe_invalidator, debounce_ms) {
                tracing::error!("watcher exited: {e:#}");
            }
        })?;
    Ok(())
}

fn run(lib: Library, debounce_ms: u64) -> Result<()> {
    let lib_for_cb = lib.clone();
    let mut debouncer = new_debouncer(
        Duration::from_millis(debounce_ms),
        None,
        move |result: notify_debouncer_full::DebounceEventResult| match result {
            Ok(events) => {
                for ev in events {
                    handle_event(&lib_for_cb, &ev);
                }
            }
            Err(errors) => {
                for e in errors {
                    tracing::warn!("watcher error: {e}");
                }
            }
        },
    )?;

    for root in lib.roots.iter() {
        tracing::info!(path = %root.path.display(), "watching");
        debouncer
            .watch(&root.path, RecursiveMode::Recursive)
            .map_err(|e| anyhow::anyhow!("watch {}: {}", root.path.display(), e))?;
    }

    // Park forever; the debouncer drives callbacks on its own thread.
    loop {
        std::thread::park();
    }
}

fn handle_event(lib: &Library, ev: &notify_debouncer_full::DebouncedEvent) {
    let paths: Vec<PathBuf> = ev.event.paths.clone();
    if paths.is_empty() {
        return;
    }

    // A directory's contents — its files, its sub-directories, and the sibling
    // `.jpg` posters that bind to them — are all determined by that one
    // directory's on-disk listing. So for every changed path we re-sync the
    // directory that *contains* it. This is idempotent: a spurious / access /
    // no-op event re-reads the same listing and converges to the same correct
    // state, instead of tearing the subtree down and losing directory posters
    // (which live only in the in-memory tree, having been folded out of the
    // browsable listing during the scan).
    let roots = Arc::clone(&lib.roots);
    lib.mutate(move |tree| {
        let mut done: Vec<PathBuf> = Vec::new();
        for abs in &paths {
            let Some(parent) = abs.parent() else { continue };
            if done.iter().any(|p| p == parent) {
                continue;
            }
            done.push(parent.to_path_buf());
            scan::resync_dir(tree, &roots, parent);
        }
        // Keep the deep-mtime invariant in sync so freshly added files bubble
        // up the ancestor chain for "Recently Added" sort/section.
        crate::library::recompute_dir_mtimes(tree);
    });
}
