use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use crate::library::{Dir, File, Library, Node, Root, Sidecar, Tree, SUB_EXTS, VIDEO_EXTS};

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
    tree
}

/// Apply a single discovered path into the tree (used by the watcher).
pub fn upsert_path(tree: &mut Tree, roots: &[Root], abs: &Path) {
    let Some((root, rel)) = resolve_relative(roots, abs) else {
        return;
    };
    let mut parts: Vec<&std::ffi::OsStr> = rel.iter().collect();
    if parts.is_empty() {
        return;
    }
    // Last part is the leaf name.
    let leaf_os = parts.pop().expect("non-empty");
    let leaf = leaf_os.to_string_lossy().into_owned();
    if is_hidden(&leaf) {
        return;
    }

    let meta = match std::fs::symlink_metadata(abs) {
        Ok(m) => m,
        Err(_) => return,
    };

    // Ensure the root branch exists.
    let root_branch = tree
        .root
        .children
        .entry(root.name.clone())
        .or_insert_with(|| Node::Dir(Dir::default()));
    let mut cur = match root_branch {
        Node::Dir(d) => d,
        _ => return,
    };
    for part in parts {
        let part_str = part.to_string_lossy().into_owned();
        if is_hidden(&part_str) {
            return;
        }
        let entry = cur
            .children
            .entry(part_str)
            .or_insert_with(|| Node::Dir(Dir::default()));
        cur = match entry {
            Node::Dir(d) => d,
            _ => return,
        };
    }

    if meta.is_dir() {
        cur.children
            .entry(leaf)
            .or_insert_with(|| Node::Dir(Dir::default()));
    } else if meta.is_file() {
        let ext = extension_of(&leaf);
        let kind = classify(&ext);
        if kind.is_none() {
            return;
        }
        let file = File {
            abs_path: abs.to_path_buf(),
            ext,
            size: meta.len(),
            mtime: meta.modified().unwrap_or(SystemTime::UNIX_EPOCH),
            sidecars: Vec::new(),
        };
        cur.children.insert(leaf, Node::File(file));
        // Re-bind sidecars for the parent directory after a change.
        attach_sidecars(cur);
    }
}

/// Remove a path from the tree if present.
pub fn remove_path(tree: &mut Tree, roots: &[Root], abs: &Path) {
    let Some((root, rel)) = resolve_relative(roots, abs) else {
        return;
    };
    let mut parts: Vec<String> = rel
        .iter()
        .map(|p| p.to_string_lossy().into_owned())
        .collect();
    if parts.is_empty() {
        return;
    }
    let leaf = parts.pop().unwrap();
    let Some(Node::Dir(root_branch)) = tree.root.children.get_mut(&root.name) else {
        return;
    };
    let mut cur = root_branch;
    for part in &parts {
        let next = cur.children.get_mut(part);
        match next {
            Some(Node::Dir(d)) => cur = d,
            _ => return,
        }
    }
    cur.children.remove(&leaf);
    attach_sidecars(cur);
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
            };
            out.children.insert(name, Node::File(file));
        }
    }
}

/// Walk a single directory level and bind sidecars (text subtitle files)
/// to their matching video files by stem.
fn attach_sidecars(dir: &mut Dir) {
    // Index sidecars in this directory keyed by stem.
    let mut sidecars: BTreeMap<String, Vec<Sidecar>> = BTreeMap::new();
    let mut to_drop_sub_names: Vec<String> = Vec::new();
    for (name, node) in &dir.children {
        if let Node::File(f) = node {
            let Some(ext) = &f.ext else { continue };
            if !SUB_EXTS.contains(&ext.as_str()) {
                continue;
            }
            let stem = strip_lang_and_ext(name);
            let lang = extract_lang(name);
            sidecars.entry(stem.to_string()).or_default().push(Sidecar {
                abs_path: f.abs_path.clone(),
                format: ext.clone(),
                language: lang,
            });
            to_drop_sub_names.push(name.clone());
        }
    }

    // Attach sidecars to matching video files (by file-name-without-ext).
    for (name, node) in dir.children.iter_mut() {
        if let Node::File(f) = node {
            let Some(ext) = &f.ext else { continue };
            if !VIDEO_EXTS.contains(&ext.as_str()) {
                continue;
            }
            let stem = strip_ext(name);
            if let Some(subs) = sidecars.get(stem) {
                f.sidecars = subs.clone();
            }
        }
    }

    // Drop the subtitle file nodes from the directory listing — they're
    // not browsable on their own; they ride on the video.
    for n in to_drop_sub_names {
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
    } else {
        None
    }
}

enum Kind {
    Video,
    Subtitle,
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
