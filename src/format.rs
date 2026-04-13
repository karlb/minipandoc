use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::Arc;

use crate::pipeline::Error;

#[derive(Clone, Debug)]
pub struct Script {
    pub name: String,
    pub source: String,
    pub path: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ScriptKind {
    Reader,
    Writer,
}

#[derive(Clone, Debug)]
pub struct FormatRegistry {
    pub data_dirs: Arc<Vec<PathBuf>>,
}

impl FormatRegistry {
    pub fn new(explicit_data_dir: Option<PathBuf>) -> Self {
        let mut dirs = Vec::new();
        if let Some(d) = explicit_data_dir {
            dirs.push(d);
        }
        if let Some(env) = std::env::var_os("MINIPANDOC_DATA_DIR") {
            dirs.push(PathBuf::from(env));
        }
        if let Some(xdg) = std::env::var_os("XDG_DATA_HOME") {
            let mut p = PathBuf::from(xdg);
            p.push("minipandoc");
            dirs.push(p);
        } else if let Some(home) = std::env::var_os("HOME") {
            let mut p = PathBuf::from(home);
            p.push(".local/share/minipandoc");
            dirs.push(p);
        }
        Self {
            data_dirs: Arc::new(dirs),
        }
    }

    pub fn load_reader(&self, name: &str) -> Result<Script, Error> {
        self.load_script(name, ScriptKind::Reader)
    }

    pub fn load_writer(&self, name: &str) -> Result<Script, Error> {
        self.load_script(name, ScriptKind::Writer)
    }

    pub fn load_script(&self, name: &str, kind: ScriptKind) -> Result<Script, Error> {
        // If `name` is a path to an existing file, load directly.
        let as_path = PathBuf::from(name);
        if as_path.is_file() {
            let source = std::fs::read_to_string(&as_path)
                .map_err(|e| Error::Io(format!("{}: {e}", as_path.display())))?;
            return Ok(Script {
                name: as_path.display().to_string(),
                source,
                path: Some(as_path.display().to_string()),
            });
        }
        let subdir = match kind {
            ScriptKind::Reader => "readers",
            ScriptKind::Writer => "writers",
        };
        for dir in self.data_dirs.iter() {
            let mut candidate = dir.clone();
            candidate.push(subdir);
            candidate.push(format!("{name}.lua"));
            if candidate.is_file() {
                let source = std::fs::read_to_string(&candidate)
                    .map_err(|e| Error::Io(format!("{}: {e}", candidate.display())))?;
                return Ok(Script {
                    name: candidate.display().to_string(),
                    source,
                    path: Some(candidate.display().to_string()),
                });
            }
        }
        // Fall back to built-in bundled scripts.
        if let Some((source, path)) = builtin_script(name, kind) {
            return Ok(Script {
                name: path.to_string(),
                source: source.to_string(),
                path: None,
            });
        }
        Err(Error::UnknownFormat(name.to_string()))
    }

    /// Load a named template (e.g. "default.html"). Searches data dirs
    /// under `templates/`, then falls back to the bundled built-ins.
    pub fn load_template(&self, name: &str) -> Option<String> {
        for dir in self.data_dirs.iter() {
            let mut candidate = dir.clone();
            candidate.push("templates");
            candidate.push(name);
            if candidate.is_file() {
                if let Ok(s) = std::fs::read_to_string(&candidate) {
                    return Some(s);
                }
            }
        }
        builtin_template(name).map(|s| s.to_string())
    }

    pub fn list_formats(&self, kind: ScriptKind) -> Vec<String> {
        let mut out = BTreeSet::new();
        for b in builtin_names(kind.clone()) {
            out.insert(b.to_string());
        }
        let subdir = match kind {
            ScriptKind::Reader => "readers",
            ScriptKind::Writer => "writers",
        };
        for dir in self.data_dirs.iter() {
            let mut d = dir.clone();
            d.push(subdir);
            if let Ok(rd) = std::fs::read_dir(&d) {
                for entry in rd.flatten() {
                    let path = entry.path();
                    if path.extension().and_then(|s| s.to_str()) == Some("lua") {
                        if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                            out.insert(stem.to_string());
                        }
                    }
                }
            }
        }
        out.into_iter().collect()
    }
}

/// Parse `base+ext1-ext2` into (base, {ext1=true, ext2=false}).
pub fn parse_extensions(s: &str) -> (String, BTreeMap<String, bool>) {
    let bytes = s.as_bytes();
    let mut base_end = bytes.len();
    for (i, b) in bytes.iter().enumerate() {
        if *b == b'+' || *b == b'-' {
            base_end = i;
            break;
        }
    }
    let base = s[..base_end].to_string();
    let mut exts = BTreeMap::new();
    let rest = &s[base_end..];
    let mut i = 0;
    let rest_bytes = rest.as_bytes();
    while i < rest_bytes.len() {
        let sign = rest_bytes[i];
        i += 1;
        let start = i;
        while i < rest_bytes.len() && rest_bytes[i] != b'+' && rest_bytes[i] != b'-' {
            i += 1;
        }
        let name = &rest[start..i];
        if !name.is_empty() {
            exts.insert(name.to_string(), sign == b'+');
        }
    }
    (base, exts)
}

// ---------------------------------------------------------------------------
// Built-in (bundled) format scripts
// ---------------------------------------------------------------------------

const NATIVE_READER: &str = include_str!("../scripts/readers/native.lua");
const NATIVE_WRITER: &str = include_str!("../scripts/writers/native.lua");
const DJOT_READER: &str = include_str!(concat!(env!("OUT_DIR"), "/djot_reader.lua"));
const DJOT_WRITER: &str = include_str!(concat!(env!("OUT_DIR"), "/djot_writer.lua"));
const HTML_WRITER: &str = include_str!("../scripts/writers/html.lua");
const PLAIN_WRITER: &str = include_str!("../scripts/writers/plain.lua");
const MARKDOWN_WRITER: &str = include_str!("../scripts/writers/markdown.lua");

pub const TEMPLATE_LUA: &str = include_str!("../scripts/template.lua");

const DEFAULT_HTML_TEMPLATE: &str = include_str!("../scripts/templates/default.html");
const DEFAULT_PLAIN_TEMPLATE: &str = include_str!("../scripts/templates/default.plain");
const DEFAULT_MARKDOWN_TEMPLATE: &str = include_str!("../scripts/templates/default.markdown");

fn builtin_template(name: &str) -> Option<&'static str> {
    match name {
        "default.html" => Some(DEFAULT_HTML_TEMPLATE),
        "default.plain" => Some(DEFAULT_PLAIN_TEMPLATE),
        "default.markdown" => Some(DEFAULT_MARKDOWN_TEMPLATE),
        _ => None,
    }
}

fn builtin_script(name: &str, kind: ScriptKind) -> Option<(&'static str, &'static str)> {
    match (name, kind) {
        ("native", ScriptKind::Reader) => Some((NATIVE_READER, "<builtin:readers/native.lua>")),
        ("native", ScriptKind::Writer) => Some((NATIVE_WRITER, "<builtin:writers/native.lua>")),
        ("djot", ScriptKind::Reader) => Some((DJOT_READER, "<builtin:readers/djot.lua>")),
        ("djot", ScriptKind::Writer) => Some((DJOT_WRITER, "<builtin:writers/djot.lua>")),
        ("html", ScriptKind::Writer) => Some((HTML_WRITER, "<builtin:writers/html.lua>")),
        ("plain", ScriptKind::Writer) => Some((PLAIN_WRITER, "<builtin:writers/plain.lua>")),
        ("markdown", ScriptKind::Writer) => {
            Some((MARKDOWN_WRITER, "<builtin:writers/markdown.lua>"))
        }
        _ => None,
    }
}

fn builtin_names(kind: ScriptKind) -> &'static [&'static str] {
    match kind {
        ScriptKind::Reader => &["djot", "native"],
        ScriptKind::Writer => &["djot", "html", "markdown", "native", "plain"],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_bare_name() {
        let (b, e) = parse_extensions("markdown");
        assert_eq!(b, "markdown");
        assert!(e.is_empty());
    }

    #[test]
    fn parses_plus_minus() {
        let (b, e) = parse_extensions("markdown+smart-footnotes+citations");
        assert_eq!(b, "markdown");
        assert_eq!(e.get("smart"), Some(&true));
        assert_eq!(e.get("footnotes"), Some(&false));
        assert_eq!(e.get("citations"), Some(&true));
    }
}
