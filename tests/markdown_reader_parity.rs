//! Markdown reader parity.
//!
//! For each `tests/fixtures/markdown/*.md` fixture, compare
//! `minipandoc -f markdown -t native` against `pandoc -f markdown -t
//! native`, both normalized through `pandoc -f native -t native` so we
//! ignore formatting differences in pandoc's native-format pretty-printer.
//!
//! Fixtures in `SMOKE_ONLY` are exercised but not required to match
//! pandoc's AST — we only assert the reader produces non-empty output
//! without erroring. These are areas where vendored lunamark diverges
//! from pandoc's markdown grammar (nested lists, simple/grid tables,
//! unindented footnote bodies, key-value attribute propagation, etc.);
//! tracked as follow-ups.
//!
//! Skips gracefully when pandoc is absent (matches `djot_parity.rs`).
//!
//! The `.md` fixtures are pandoc-generated from the sibling `.native`
//! files via `pandoc -f native -t markdown`, so they reflect real
//! pandoc writer output.

mod common;

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

fn fixtures_dir() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.extend(["tests", "fixtures", "markdown"]);
    p
}

fn run_minipandoc(args: &[&str], input_path: &Path) -> String {
    let out = Command::new(common::binary_path())
        .args(args)
        .arg(input_path)
        .stderr(Stdio::inherit())
        .output()
        .expect("spawn minipandoc");
    assert!(
        out.status.success(),
        "minipandoc failed on {}: {}",
        input_path.display(),
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).expect("utf8")
}

fn run_pandoc(args: &[&str], input_path: &Path) -> String {
    let out = Command::new("pandoc")
        .args(args)
        .arg(input_path)
        .stderr(Stdio::inherit())
        .output()
        .expect("spawn pandoc");
    assert!(
        out.status.success(),
        "pandoc failed on {}",
        input_path.display()
    );
    String::from_utf8(out.stdout).expect("utf8")
}

fn run_pandoc_native(input: &str) -> String {
    let mut child = Command::new("pandoc")
        .args(["-f", "native", "-t", "native"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success());
    String::from_utf8(out.stdout).unwrap()
}

fn fixtures() -> Vec<PathBuf> {
    let mut v: Vec<_> = std::fs::read_dir(fixtures_dir())
        .expect("read markdown fixtures dir")
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("md"))
        .collect();
    v.sort();
    v
}

/// Fixtures where we don't assert byte-level AST parity with pandoc.
/// The reader still has to run and emit non-empty output. Each entry
/// notes which lunamark limitation the divergence hits.
const SMOKE_ONLY: &[&str] = &[
    // Grid tables: lunamark parses only pipe tables.
    "complex_table.md",
    // Pandoc's "simple" indented table form (no `|` delimiters): not
    // supported by lunamark.
    "table.md",
    // Pandoc writer emits footnote definitions with the body on the
    // same line as the marker (`[^1]: body`); lunamark's `NoteBlock`
    // parser requires a 4-space-indented body after the colon.
    "footnote.md",
    // Nested bullet lists: lunamark's list parser doesn't recognize
    // indentation-based nesting the way pandoc does.
    "lists.md",
    // YAML metadata: lunamark's pandoc_title_blocks only handles the
    // `% Title / % Author / % Date` form; pandoc-writer emits `---` /
    // `...` YAML blocks that lunamark treats as content.
    "meta.md",
    // Key-value attributes (`{foo="bar" baz="qq qq"}`) on headers and
    // link_attributes on images are dropped by lunamark.
    "header_attrs.md",
    "figure.md",
    // `escaped_line_breaks` ext difference: lunamark emits Space,
    // pandoc emits SoftBreak on escaped newlines.
    "escapes.md",
];

#[test]
fn reader_semantic_parity() {
    if !common::pandoc_available() {
        eprintln!("note: pandoc not on PATH — skipping markdown reader parity test");
        return;
    }
    let fs = fixtures();
    assert!(!fs.is_empty(), "no markdown fixtures");
    let mut strict = 0usize;
    let mut smoke = 0usize;
    for fx in fs {
        let name = fx.file_name().unwrap().to_string_lossy().into_owned();
        let mp = run_minipandoc(&["-f", "markdown", "-t", "native"], &fx);
        if SMOKE_ONLY.contains(&name.as_str()) {
            assert!(!mp.trim().is_empty(), "{name}: reader produced empty output");
            smoke += 1;
            continue;
        }
        let pd = run_pandoc(&["-f", "markdown", "-t", "native"], &fx);
        let mp_norm = run_pandoc_native(&mp);
        let pd_norm = run_pandoc_native(&pd);
        assert_eq!(mp_norm, pd_norm, "{name}: reader parity broken");
        strict += 1;
    }
    eprintln!(
        "markdown reader parity: {strict} strict, {smoke} smoke-only (see SMOKE_ONLY)"
    );
}
