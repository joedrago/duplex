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

/// Recognised sidecar poster image extensions (always JPEG internally).
pub const POSTER_EXTS: &[&str] = &["jpg", "jpeg"];

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

#[derive(Debug)]
pub struct Dir {
    pub children: BTreeMap<String, Node>,
    /// "Deep" mtime: the maximum mtime of any descendant file (or the directory's
    /// own mtime if it has no descendants). Computed by scan and refreshed by
    /// the watcher. Used by browse to sort by Recently Added in a way that
    /// surfaces freshly-added files inside deep subtrees.
    pub mtime: SystemTime,
    /// Sidecar poster for this directory: a sibling `.jpg`/`.jpeg` in the
    /// *parent* directory sharing this dir's name (e.g. `Another Show.jpg`
    /// next to `Another Show/`). Videos inside that have no explicit poster
    /// inherit the nearest ancestor directory's poster — see
    /// `Tree::inherited_dir_poster`.
    pub poster: Option<PathBuf>,
}

impl Default for Dir {
    fn default() -> Self {
        Self {
            children: BTreeMap::new(),
            mtime: SystemTime::UNIX_EPOCH,
            poster: None,
        }
    }
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
    /// Sidecar poster image (a sibling `.jpg`/`.jpeg` sharing the same stem),
    /// if one exists. Served by `/api/poster`; only its presence reaches the
    /// wire (as a `poster: bool` flag on browse/recent file entries).
    pub poster: Option<PathBuf>,
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

    /// Nearest sidecar poster for `dir_vpath`, searching that directory itself
    /// and then each ancestor (deepest first). Returns the first directory
    /// poster found, so a video with no explicit poster of its own can inherit
    /// the closest enclosing directory's poster. Empty path (virtual root) has
    /// no poster.
    pub fn inherited_dir_poster(&self, dir_vpath: &str) -> Option<PathBuf> {
        let mut parts: Vec<&str> = dir_vpath.split('/').filter(|s| !s.is_empty()).collect();
        while !parts.is_empty() {
            let prefix = parts.join("/");
            if let Some(Node::Dir(d)) = self.lookup(&prefix) {
                if let Some(poster) = &d.poster {
                    return Some(poster.clone());
                }
            }
            parts.pop();
        }
        None
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
    let mut out = Dir {
        mtime: d.mtime,
        poster: d.poster.clone(),
        ..Dir::default()
    };
    for (k, v) in &d.children {
        out.children.insert(k.clone(), clone_node(v));
    }
    out
}

/// Walk a tree post-order and set each directory's `mtime` to the maximum
/// mtime of any descendant file. A directory with no file descendants keeps
/// the default `UNIX_EPOCH`. Called from scan after building the tree, and
/// from the watcher after mutating it.
pub fn recompute_dir_mtimes(tree: &mut Tree) {
    recompute_dir_mtimes_inner(&mut tree.root);
}

fn recompute_dir_mtimes_inner(d: &mut Dir) -> SystemTime {
    let mut m = SystemTime::UNIX_EPOCH;
    for child in d.children.values_mut() {
        let cm = match child {
            Node::File(f) => f.mtime,
            Node::Dir(sub) => recompute_dir_mtimes_inner(sub),
        };
        if cm > m {
            m = cm;
        }
    }
    d.mtime = m;
    m
}

fn clone_node(n: &Node) -> Node {
    match n {
        Node::Dir(d) => Node::Dir(clone_dir(d)),
        Node::File(f) => Node::File(f.clone()),
    }
}
