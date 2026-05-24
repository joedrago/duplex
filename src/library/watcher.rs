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

    let roots = Arc::clone(&lib.roots);
    lib.mutate(move |tree| {
        for abs in &paths {
            // Remove any existing entry, then re-add from disk (if it still exists).
            scan::remove_path(tree, &roots, abs);
            if std::fs::symlink_metadata(abs).is_ok() {
                // Refresh by walking just the affected file's parent directory
                // for cheap. For directories, fall back to a full subtree
                // re-add via the path itself.
                if abs.is_dir() {
                    re_add_subtree(tree, &roots, abs);
                } else {
                    scan::upsert_path(tree, &roots, abs);
                }
            }
        }
        // Keep the deep-mtime invariant in sync so freshly added files bubble
        // up the ancestor chain for "Recently Added" sort/section.
        crate::library::recompute_dir_mtimes(tree);
    });
}

fn re_add_subtree(
    tree: &mut crate::library::Tree,
    roots: &[crate::library::Root],
    abs: &std::path::Path,
) {
    // Walk the subtree manually and upsert each file.
    let Ok(read) = std::fs::read_dir(abs) else {
        return;
    };
    for entry in read.flatten() {
        let p = entry.path();
        let Ok(meta) = entry.metadata() else { continue };
        if meta.is_dir() {
            re_add_subtree(tree, roots, &p);
        } else if meta.is_file() {
            scan::upsert_path(tree, roots, &p);
        }
    }
}
