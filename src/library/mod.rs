use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::SystemTime;

use anyhow::{anyhow, Result};
use arc_swap::ArcSwap;
use serde::Serialize;

pub mod scan;
pub mod watcher;

/// Recognised video extensions (lowercased, no dot).
pub const VIDEO_EXTS: &[&str] = &["mp4", "mkv", "mov", "webm", "m4v"];

/// Recognised sidecar subtitle extensions.
pub const SUB_EXTS: &[&str] = &["srt", "vtt", "ass"];

/// One library root, addressed by its virtual name (basename by default).
#[derive(Debug, Clone)]
pub struct Root {
    pub name: String,
    pub path: PathBuf,
}

/// A node in the in-memory tree. Directories own their children by name;
/// files carry enough metadata to drive browse responses without I/O.
#[derive(Debug)]
pub enum Node {
    Dir(Dir),
    File(File),
}

#[derive(Debug, Default)]
pub struct Dir {
    pub children: BTreeMap<String, Node>,
}

#[derive(Debug, Clone)]
pub struct File {
    /// Absolute path on disk.
    pub abs_path: PathBuf,
    /// Lowercased extension without a dot, if any.
    pub ext: Option<String>,
    pub size: u64,
    pub mtime: SystemTime,
    /// Sidecar subtitle files (siblings sharing the same stem).
    pub sidecars: Vec<Sidecar>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Sidecar {
    /// Absolute path on disk.
    #[serde(skip_serializing)]
    pub abs_path: PathBuf,
    /// e.g. "srt", "vtt", "ass".
    pub format: String,
    /// Inferred language tag from filename suffix (e.g. `Movie.en.srt` -> "en"),
    /// or None if not present.
    pub language: Option<String>,
}

/// Top of the virtual tree. The virtual root is a directory whose children are
/// the configured library roots (by name).
#[derive(Debug, Default)]
pub struct Tree {
    pub root: Dir,
}

impl Tree {
    /// Look up a node by a `/`-separated virtual path (no leading slash).
    /// An empty string returns the virtual root.
    pub fn lookup(&self, vpath: &str) -> Option<&Node> {
        if vpath.is_empty() {
            // Special: return a synthetic reference to the root directory.
            // Callers that need this case typically check is_empty themselves;
            // we expose it via a dedicated helper below.
            return None;
        }
        let mut cur = &self.root;
        let parts: Vec<&str> = vpath.split('/').filter(|s| !s.is_empty()).collect();
        if parts.is_empty() {
            return None;
        }
        for (i, part) in parts.iter().enumerate() {
            let child = cur.children.get(*part)?;
            if i + 1 == parts.len() {
                return Some(child);
            }
            match child {
                Node::Dir(d) => cur = d,
                Node::File(_) => return None,
            }
        }
        None
    }

    pub fn root_dir(&self) -> &Dir {
        &self.root
    }
}

/// Snapshot-style library wrapper. Reads are lock-free via arc-swap; writes
/// (scan + watcher mutations) build a new Tree and swap it in.
#[derive(Clone)]
pub struct Library {
    pub roots: Arc<Vec<Root>>,
    inner: Arc<ArcSwap<Tree>>,
}

impl Library {
    /// Build a Library from a list of root paths. Returns an error if two
    /// roots collide on basename — the user must rename one of them.
    pub fn new(paths: &[PathBuf]) -> Result<Self> {
        let mut roots: Vec<Root> = Vec::with_capacity(paths.len());
        for p in paths {
            let canonical = std::fs::canonicalize(p)
                .map_err(|e| anyhow!("library path {}: {}", p.display(), e))?;
            let name = canonical
                .file_name()
                .and_then(|n| n.to_str())
                .ok_or_else(|| anyhow!("library path {} has no usable basename", p.display()))?
                .to_string();
            if roots.iter().any(|r| r.name == name) {
                return Err(anyhow!(
                    "two library roots share the basename {:?}: rename one of them on disk",
                    name
                ));
            }
            if !canonical.is_dir() {
                return Err(anyhow!(
                    "library path {} is not a directory",
                    canonical.display()
                ));
            }
            roots.push(Root {
                name,
                path: canonical,
            });
        }
        Ok(Self {
            roots: Arc::new(roots),
            inner: Arc::new(ArcSwap::from_pointee(Tree::default())),
        })
    }

    /// Replace the entire tree (used after a full scan).
    pub fn replace(&self, tree: Tree) {
        self.inner.store(Arc::new(tree));
    }

    /// Atomically read the current tree.
    pub fn snapshot(&self) -> Arc<Tree> {
        self.inner.load_full()
    }

    /// Apply a mutation function: clone current tree, mutate, swap in.
    /// Coarse but correct; mutations are infrequent compared to reads.
    pub fn mutate<F: FnOnce(&mut Tree)>(&self, f: F) {
        let mut new_tree = clone_tree(&self.inner.load());
        f(&mut new_tree);
        self.inner.store(Arc::new(new_tree));
    }
}

fn clone_tree(t: &Tree) -> Tree {
    Tree {
        root: clone_dir(&t.root),
    }
}

fn clone_dir(d: &Dir) -> Dir {
    let mut out = Dir::default();
    for (k, v) in &d.children {
        out.children.insert(k.clone(), clone_node(v));
    }
    out
}

fn clone_node(n: &Node) -> Node {
    match n {
        Node::Dir(d) => Node::Dir(clone_dir(d)),
        Node::File(f) => Node::File(f.clone()),
    }
}
