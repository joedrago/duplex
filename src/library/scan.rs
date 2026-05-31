use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use crate::library::{
    recompute_dir_mtimes, Dir, File, Library, Node, Root, Sidecar, Tree, POSTER_EXTS, SUB_EXTS,
    VIDEO_EXTS,
};

/// Build a fresh Tree by walking every configured root.
pub fn scan(lib: &Library) -> Tree {
    let mut tree = Tree::default();
    for root in lib.roots.iter() {
        let mut root_dir = Dir::default();
        scan_dir(&root.path, &mut root_dir);
        attach_sidecars(&mut root_dir);
        tree.root
            .children
            .insert(root.name.clone(), Node::Dir(root_dir));
    }
    recompute_dir_mtimes(&mut tree);
    tree
}

/// Re-sync a single directory's listing from disk into the tree.
///
/// This is the watcher's one and only mutation primitive. Given the absolute
/// path of a directory whose contents may have changed, it re-reads that
/// directory's immediate entries from disk and rebuilds the corresponding tree
/// node, then re-binds sidecars/posters at this level via `attach_sidecars`.
///
/// Crucially it is **idempotent and non-destructive**: existing child *Dir*
/// subtrees are reused untouched (their own contents stay in sync via their
/// own events), and posters are re-derived from the sibling `.jpg`s actually
/// present on disk. Firing it on a no-op event (e.g. an access/stat event that
/// carries no real change) reproduces the exact same correct state rather than
/// tearing a subtree down and losing the directory posters that only live in
/// the in-memory tree. If `dir_abs` no longer exists on disk, the node is
/// removed. Ancestors are created as needed.
pub fn resync_dir(tree: &mut Tree, roots: &[Root], dir_abs: &Path) {
    let Some((root, rel)) = resolve_relative(roots, dir_abs) else {
        return;
    };
    let parts: Vec<String> = rel
        .iter()
        .map(|p| p.to_string_lossy().into_owned())
        .collect();
    if parts.iter().any(|p| is_hidden(p)) {
        return;
    }

    // Gone from disk → drop the node from the tree.
    if !dir_abs.is_dir() {
        remove_node(tree, &root.name, &parts);
        return;
    }

    let read = match std::fs::read_dir(dir_abs) {
        Ok(r) => r,
        Err(e) => {
            tracing::warn!("read_dir {} failed: {}", dir_abs.display(), e);
            return;
        }
    };

    let Some(dir) = dir_node_mut(tree, &root.name, &parts) else {
        return;
    };

    // Take the old children so we can reuse existing sub-directory subtrees;
    // everything not seen on disk this pass is dropped (handles deletions).
    let mut old: BTreeMap<String, Node> = std::mem::take(&mut dir.children);
    for entry in read.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if is_hidden(&name) {
            continue;
        }
        let Ok(meta) = entry.metadata() else { continue };
        if meta.is_dir() {
            // Reuse the existing subtree if we have one; otherwise scan the
            // new sub-directory fresh (and skip it if it holds nothing).
            match old.remove(&name) {
                Some(existing @ Node::Dir(_)) => {
                    dir.children.insert(name, existing);
                }
                _ => {
                    let mut child = Dir::default();
                    scan_dir(&entry.path(), &mut child);
                    attach_sidecars(&mut child);
                    if !child.children.is_empty() {
                        dir.children.insert(name, Node::Dir(child));
                    }
                }
            }
        } else if meta.is_file() {
            let ext = extension_of(&name);
            if classify(&ext).is_none() {
                continue;
            }
            let file = File {
                abs_path: entry.path(),
                ext,
                size: meta.len(),
                mtime: meta.modified().unwrap_or(SystemTime::UNIX_EPOCH),
                sidecars: Vec::new(),
                poster: None,
            };
            dir.children.insert(name, Node::File(file));
        }
    }
    attach_sidecars(dir);
}

/// Navigate to the `Dir` node at `root_name`/`parts`, creating intermediate
/// (and the final) directories as needed. Returns `None` if the path would
/// have to cross a `File` node.
fn dir_node_mut<'a>(tree: &'a mut Tree, root_name: &str, parts: &[String]) -> Option<&'a mut Dir> {
    let root_branch = tree
        .root
        .children
        .entry(root_name.to_string())
        .or_insert_with(|| Node::Dir(Dir::default()));
    let mut cur = match root_branch {
        Node::Dir(d) => d,
        _ => return None,
    };
    for part in parts {
        let entry = cur
            .children
            .entry(part.clone())
            .or_insert_with(|| Node::Dir(Dir::default()));
        cur = match entry {
            Node::Dir(d) => d,
            _ => return None,
        };
    }
    Some(cur)
}

/// Remove the node at `root_name`/`parts` from the tree if present.
fn remove_node(tree: &mut Tree, root_name: &str, parts: &[String]) {
    let Some((leaf, ancestors)) = parts.split_last() else {
        // Empty path == the root itself vanished; drop the whole root branch.
        tree.root.children.remove(root_name);
        return;
    };
    let Some(Node::Dir(root_branch)) = tree.root.children.get_mut(root_name) else {
        return;
    };
    let mut cur = root_branch;
    for part in ancestors {
        match cur.children.get_mut(part) {
            Some(Node::Dir(d)) => cur = d,
            _ => return,
        }
    }
    cur.children.remove(leaf);
}

fn resolve_relative<'a>(roots: &'a [Root], abs: &Path) -> Option<(&'a Root, PathBuf)> {
    for r in roots {
        if let Ok(rel) = abs.strip_prefix(&r.path) {
            return Some((r, rel.to_path_buf()));
        }
    }
    None
}

fn scan_dir(abs: &Path, out: &mut Dir) {
    let read = match std::fs::read_dir(abs) {
        Ok(r) => r,
        Err(e) => {
            tracing::warn!("read_dir {} failed: {}", abs.display(), e);
            return;
        }
    };
    for entry in read.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if is_hidden(&name) {
            continue;
        }
        let meta = match entry.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };
        if meta.is_dir() {
            let mut child = Dir::default();
            scan_dir(&entry.path(), &mut child);
            attach_sidecars(&mut child);
            if !child.children.is_empty() {
                out.children.insert(name, Node::Dir(child));
            }
        } else if meta.is_file() {
            let ext = extension_of(&name);
            if classify(&ext).is_none() {
                continue;
            }
            let file = File {
                abs_path: entry.path(),
                ext,
                size: meta.len(),
                mtime: meta.modified().unwrap_or(SystemTime::UNIX_EPOCH),
                sidecars: Vec::new(),
                poster: None,
            };
            out.children.insert(name, Node::File(file));
        }
    }
}

/// Walk a single directory level and bind sidecars (text subtitle files and a
/// poster image) to their matching video files by stem.
fn attach_sidecars(dir: &mut Dir) {
    // Index sidecars in this directory keyed by stem.
    let mut sidecars: BTreeMap<String, Vec<Sidecar>> = BTreeMap::new();
    // Poster images keyed by exact stem (`Movie.jpg` -> "Movie").
    let mut posters: BTreeMap<String, PathBuf> = BTreeMap::new();
    let mut to_drop_names: Vec<String> = Vec::new();
    for (name, node) in &dir.children {
        if let Node::File(f) = node {
            let Some(ext) = &f.ext else { continue };
            if SUB_EXTS.contains(&ext.as_str()) {
                let stem = strip_lang_and_ext(name);
                let lang = extract_lang(name);
                sidecars.entry(stem.to_string()).or_default().push(Sidecar {
                    abs_path: f.abs_path.clone(),
                    format: ext.clone(),
                    language: lang,
                });
                to_drop_names.push(name.clone());
            } else if POSTER_EXTS.contains(&ext.as_str()) {
                // Last writer wins if two extensions share a stem; rare.
                posters.insert(strip_ext(name).to_string(), f.abs_path.clone());
                to_drop_names.push(name.clone());
            }
        }
    }

    // Attach sidecars and a poster to matching video files (by file-name-
    // without-ext), and a poster to matching sub-directories (by dir name) so
    // `Another Show.jpg` next to `Another Show/` becomes that dir's poster.
    //
    // This is authoritative and idempotent for *this* directory level: each
    // immediate child's sidecars/poster are fully determined by the sibling
    // files present here, so we always overwrite — setting on a match and
    // CLEARING on no match. That lets the watcher re-run this over an existing
    // (possibly stale) subtree and converge to the correct state instead of
    // leaving a poster bound to a `.jpg` that is no longer here.
    for (name, node) in dir.children.iter_mut() {
        match node {
            Node::File(f) => {
                let Some(ext) = &f.ext else { continue };
                if !VIDEO_EXTS.contains(&ext.as_str()) {
                    continue;
                }
                let stem = strip_ext(name);
                f.sidecars = sidecars.get(stem).cloned().unwrap_or_default();
                f.poster = posters.get(stem).cloned();
            }
            Node::Dir(d) => {
                d.poster = posters.get(name.as_str()).cloned();
            }
        }
    }

    // Drop the sidecar (subtitle + poster) file nodes from the directory
    // listing — they're not browsable on their own; they ride on the video.
    for n in to_drop_names {
        dir.children.remove(&n);
    }
}

fn is_hidden(name: &str) -> bool {
    name.starts_with('.')
}

fn extension_of(name: &str) -> Option<String> {
    Path::new(name)
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
}

fn classify(ext: &Option<String>) -> Option<Kind> {
    let e = ext.as_deref()?;
    if VIDEO_EXTS.contains(&e) {
        Some(Kind::Video)
    } else if SUB_EXTS.contains(&e) {
        Some(Kind::Subtitle)
    } else if POSTER_EXTS.contains(&e) {
        Some(Kind::Poster)
    } else {
        None
    }
}

enum Kind {
    Video,
    Subtitle,
    Poster,
}

fn strip_ext(name: &str) -> &str {
    match name.rfind('.') {
        Some(i) => &name[..i],
        None => name,
    }
}

/// `Movie.en.srt` -> "Movie"; `Movie.srt` -> "Movie".
fn strip_lang_and_ext(name: &str) -> &str {
    let no_ext = strip_ext(name);
    // If what's left has a trailing `.xx` or `.xxx` looking like a language code, drop it.
    if let Some(i) = no_ext.rfind('.') {
        let suffix = &no_ext[i + 1..];
        if (2..=3).contains(&suffix.len()) && suffix.chars().all(|c| c.is_ascii_alphabetic()) {
            return &no_ext[..i];
        }
    }
    no_ext
}

fn extract_lang(name: &str) -> Option<String> {
    let no_ext = strip_ext(name);
    let i = no_ext.rfind('.')?;
    let suffix = &no_ext[i + 1..];
    if (2..=3).contains(&suffix.len()) && suffix.chars().all(|c| c.is_ascii_alphabetic()) {
        Some(suffix.to_lowercase())
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library::Root;
    use std::sync::atomic::{AtomicU32, Ordering};

    static SEQ: AtomicU32 = AtomicU32::new(0);

    fn scratch() -> PathBuf {
        let n = SEQ.fetch_add(1, Ordering::Relaxed);
        let p =
            std::env::temp_dir().join(format!("duplex-postertest-{}-{}", std::process::id(), n));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        // Canonicalize so paths match Library::new's canonicalized roots
        // (macOS /var -> /private/var symlink would otherwise break
        // strip_prefix in the watcher path-resolution).
        std::fs::canonicalize(&p).unwrap()
    }

    fn touch(p: &Path) {
        if let Some(parent) = p.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        std::fs::write(p, b"x").unwrap();
    }

    /// Build the prod-style layout: a `Foo.jpg` sibling next to `Foo/`,
    /// with two season subdirs each holding an episode.
    fn build_foo(root: &Path) {
        touch(&root.join("TV/Foo.jpg"));
        touch(&root.join("TV/Foo/S01/S01E01.mp4"));
        touch(&root.join("TV/Foo/S02/S02E01.mp4"));
    }

    fn lib_for(root: &Path) -> (Library, Vec<Root>) {
        let lib = Library::new(&[root.to_path_buf()]).unwrap();
        let roots = (*lib.roots).clone();
        (lib, roots)
    }

    // ---- the dir node lookup helper (lookup() returns None for root only) ----
    fn dir_poster(tree: &Tree, vpath: &str) -> Option<PathBuf> {
        match tree.lookup(vpath) {
            Some(Node::Dir(d)) => d.poster.clone(),
            _ => None,
        }
    }

    #[test]
    fn fresh_scan_attaches_dir_poster() {
        let root = scratch();
        build_foo(&root);
        let (lib, _roots) = lib_for(&root);
        let tree = scan(&lib);
        let name = lib.roots[0].name.clone();

        // Foo/ should carry the sidecar poster.
        let foo = format!("{name}/TV/Foo");
        assert!(
            dir_poster(&tree, &foo).is_some(),
            "fresh scan: Foo/ should have a poster"
        );
        // Seasons inherit it.
        assert!(
            tree.inherited_dir_poster(&format!("{name}/TV/Foo/S01"))
                .is_some(),
            "fresh scan: S01 should inherit Foo's poster"
        );
        std::fs::remove_dir_all(&root).ok();
    }

    /// Replay what the watcher's `handle_event` does for a batch of changed
    /// paths: re-sync the directory containing each one (deduped), then refresh
    /// deep mtimes.
    fn fire(tree: &mut Tree, roots: &[Root], changed: &[PathBuf]) {
        let mut done: Vec<PathBuf> = Vec::new();
        for abs in changed {
            let Some(parent) = abs.parent() else { continue };
            if done.iter().any(|p| p == parent) {
                continue;
            }
            done.push(parent.to_path_buf());
            resync_dir(tree, roots, parent);
        }
        crate::library::recompute_dir_mtimes(tree);
    }

    #[test]
    fn no_op_dir_event_preserves_poster() {
        // The reported bug: disk is static, but browsing triggers access/stat
        // events. A no-change event on the Foo directory must NOT lose its
        // poster.
        let root = scratch();
        build_foo(&root);
        let (lib, roots) = lib_for(&root);
        let mut tree = scan(&lib);
        let name = lib.roots[0].name.clone();
        let foo_vp = format!("{name}/TV/Foo");
        assert!(dir_poster(&tree, &foo_vp).is_some(), "precondition");

        // Event paths the watcher might receive while browsing, with no disk
        // change at all: the directory itself and its episodes.
        fire(
            &mut tree,
            &roots,
            &[
                root.join("TV/Foo"),
                root.join("TV/Foo/S01/S01E01.mp4"),
                root.join("TV/Foo/S02/S02E01.mp4"),
            ],
        );

        assert!(
            dir_poster(&tree, &foo_vp).is_some(),
            "BUG: a no-op watcher event wiped Foo's poster"
        );
        assert!(
            tree.inherited_dir_poster(&format!("{name}/TV/Foo/S01"))
                .is_some(),
            "BUG: a no-op watcher event broke season inheritance"
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn repeated_events_are_idempotent() {
        // Browsing fires events repeatedly; the poster state must be stable.
        let root = scratch();
        build_foo(&root);
        let (lib, roots) = lib_for(&root);
        let mut tree = scan(&lib);
        let name = lib.roots[0].name.clone();
        let foo_vp = format!("{name}/TV/Foo");

        for _ in 0..5 {
            fire(
                &mut tree,
                &roots,
                &[
                    root.join("TV"),
                    root.join("TV/Foo"),
                    root.join("TV/Foo/S01/S01E01.mp4"),
                ],
            );
            assert!(
                dir_poster(&tree, &foo_vp).is_some(),
                "BUG: poster lost after repeated events"
            );
        }
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn deleting_poster_clears_it() {
        let root = scratch();
        build_foo(&root);
        let (lib, roots) = lib_for(&root);
        let mut tree = scan(&lib);
        let name = lib.roots[0].name.clone();
        let foo_vp = format!("{name}/TV/Foo");
        assert!(dir_poster(&tree, &foo_vp).is_some(), "precondition");

        // User actually deletes Foo.jpg; the watcher re-syncs its parent (TV).
        let jpg = root.join("TV/Foo.jpg");
        std::fs::remove_file(&jpg).unwrap();
        fire(&mut tree, &roots, &[jpg]);

        assert!(
            dir_poster(&tree, &foo_vp).is_none(),
            "BUG: deleting Foo.jpg left a stale poster on Foo/"
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn adding_poster_binds_it() {
        // Start without a poster, then add Foo.jpg and fire the parent event.
        let root = scratch();
        touch(&root.join("TV/Foo/S01/S01E01.mp4"));
        let (lib, roots) = lib_for(&root);
        let mut tree = scan(&lib);
        let name = lib.roots[0].name.clone();
        let foo_vp = format!("{name}/TV/Foo");
        assert!(dir_poster(&tree, &foo_vp).is_none(), "precondition");

        let jpg = root.join("TV/Foo.jpg");
        touch(&jpg);
        fire(&mut tree, &roots, &[jpg]);

        assert!(
            dir_poster(&tree, &foo_vp).is_some(),
            "BUG: adding Foo.jpg did not bind the poster"
        );
        std::fs::remove_dir_all(&root).ok();
    }
}
