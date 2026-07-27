use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::SystemTime;

use anyhow::{anyhow, Result};
use arc_swap::ArcSwap;
use serde::{Deserialize, Serialize};

pub mod scan;
pub mod watcher;

/// Recognised video extensions (lowercased, no dot).
pub const VIDEO_EXTS: &[&str] = &["mp4", "mkv", "mov", "webm", "m4v"];

/// Recognised sidecar subtitle extensions.
pub const SUB_EXTS: &[&str] = &["srt", "vtt", "ass"];

/// Recognised sidecar poster image extensions (always JPEG internally).
pub const POSTER_EXTS: &[&str] = &["jpg", "jpeg"];

/// Recognised sidecar metadata extensions — see `Meta`.
pub const META_EXTS: &[&str] = &["json"];

/// One library root, addressed by its virtual name (basename by default).
#[derive(Debug, Clone)]
pub struct Root {
    pub name: String,
    pub path: PathBuf,

    /// When true this root is mounted, watched, and playable by exact vpath
    /// like any other, but withheld from every enumeration surface — root
    /// browse, "recently added", folder-flatten, and substring search. It
    /// surfaces only when the search query is an exact, case-sensitive match
    /// for `name`, which returns it as a single browseable directory. See
    /// `Library::is_hidden_root` and the guards in the `api` enumeration
    /// handlers.
    pub hidden: bool,
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

    /// Parsed sidecar JSON for a *movie folder*: a sibling `.json` in the
    /// parent sharing this dir's name, same convention as the dir poster. Lets
    /// the one-folder-per-movie layout carry a title the same way a bare file
    /// does.
    pub meta: Option<Meta>,
}

impl Default for Dir {
    fn default() -> Self {
        Self {
            children: BTreeMap::new(),
            mtime: SystemTime::UNIX_EPOCH,
            poster: None,
            meta: None,
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

    /// Parsed sidecar JSON (a sibling `.json` sharing the same stem), if one
    /// exists and parsed. Overrides display title/year and pins the Letterboxd
    /// match — see `Meta`.
    pub meta: Option<Meta>,
}

/// The optional sidecar JSON that can sit next to a movie file or movie folder
/// (`Birdman (2014).json`, exactly like `Birdman (2014).jpg`). Read once at
/// scan time and attached to the node it names, so browse/search/recent can
/// use it without touching the disk per row.
///
/// It overrides *presentation* only. The entry's `name` — and therefore its
/// vpath, playback URL, and focus identity — always stays the real filename,
/// and `mtime` always stays the video's own. Only the displayed title, the
/// sort/bucket key, and the Letterboxd correlation come from here.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct Meta {
    /// Letterboxd slug (`birdman`) or full film URL. Exact match, beats the
    /// title/year guesser.
    pub letterboxd: Option<String>,
    /// TMDB movie id. Exact match (alternative to `letterboxd`).
    pub tmdb: Option<u32>,
    pub title: Option<String>,
    pub description: Option<String>,
    pub tagline: Option<String>,
    pub year: Option<u16>,
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
    /// Build a Library from visible (`--library`) and hidden (`--hidden`) root
    /// paths. Both kinds are mounted into the same virtual namespace and are
    /// addressable, browseable, and playable by vpath; hidden roots merely set
    /// `Root::hidden` so the API can filter them out of every enumeration
    /// surface (see `is_hidden_root`). Returns an error if any two roots —
    /// regardless of kind — collide on basename, since they would then be
    /// indistinguishable by vpath; the user must rename one on disk.
    pub fn new(visible: &[PathBuf], hidden: &[PathBuf]) -> Result<Self> {
        let mut roots: Vec<Root> = Vec::with_capacity(visible.len() + hidden.len());
        for (paths, is_hidden) in [(visible, false), (hidden, true)] {
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
                    hidden: is_hidden,
                });
            }
        }
        Ok(Self {
            roots: Arc::new(roots),
            inner: Arc::new(ArcSwap::from_pointee(Tree::default())),
        })
    }

    /// Whether `name` (a top-level virtual directory / library basename) belongs
    /// to a `--hidden` root. The API enumeration handlers consult this to keep
    /// hidden roots out of root browse, recent, flatten-from-root, and search.
    pub fn is_hidden_root(&self, name: &str) -> bool {
        self.roots.iter().any(|r| r.hidden && r.name == name)
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
        meta: d.meta.clone(),
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
