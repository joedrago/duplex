use std::path::{Component, PathBuf};

use percent_encoding::{percent_decode_str, utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};

/// Characters we leave untouched in encoded URL path segments. Most punctuation
/// is encoded; we keep a small set that HLS players (and Safari) handle reliably.
pub const PATH_ESCAPE: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'_')
    .remove(b'.')
    .remove(b'~');

/// Normalise a user-supplied virtual path:
/// * decode percent-escapes
/// * reject absolute paths, `..`, NUL, empty segments
/// * return components joined with '/'
pub fn normalize(input: &str) -> Option<String> {
    let decoded = percent_decode_str(input).decode_utf8().ok()?.into_owned();
    let pb = PathBuf::from(&decoded);
    let mut out = String::with_capacity(decoded.len());
    for comp in pb.components() {
        match comp {
            Component::Normal(seg) => {
                let s = seg.to_str()?;
                if s.is_empty() || s.contains('\0') {
                    return None;
                }
                if !out.is_empty() {
                    out.push('/');
                }
                out.push_str(s);
            }
            Component::CurDir => continue,
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => return None,
        }
    }
    Some(out)
}

/// Encode a virtual path for safe inclusion in a URL.
pub fn encode(vpath: &str) -> String {
    vpath
        .split('/')
        .map(|seg| utf8_percent_encode(seg, PATH_ESCAPE).to_string())
        .collect::<Vec<_>>()
        .join("/")
}
