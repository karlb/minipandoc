//! HTML writer parity.
//!
//! For each `.native` fixture, feed `minipandoc -f native -t html` through
//! `pandoc -f html -t native`. The resulting AST — modulo unavoidable HTML
//! round-trip losses (OrderedList delimiter style, etc.) — must equal the
//! original fixture normalized through pandoc.
//!
//! Fixtures with constructs that HTML can't preserve losslessly (`Quoted`,
//! `Math`, `RawInline`/`RawBlock` in a non-HTML format, inline HTML raws
//! parsed as elements) are exercised only as smoke tests — the writer must
//! run and emit something that pandoc's HTML reader accepts.
//!
//! Skips gracefully when pandoc is absent.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

fn binary_path() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("target");
    p.push(if cfg!(debug_assertions) { "debug" } else { "release" });
    p.push("minipandoc");
    p
}

fn fixtures_root() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.extend(["tests", "fixtures"]);
    p
}

fn pandoc_available() -> bool {
    Command::new("pandoc")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn run_minipandoc(args: &[&str], input_path: &Path) -> String {
    let out = Command::new(binary_path())
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

fn run_pandoc(args: &[&str], stdin_bytes: &[u8]) -> String {
    use std::io::Write;
    let mut child = Command::new("pandoc")
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn pandoc");
    child.stdin.as_mut().unwrap().write_all(stdin_bytes).unwrap();
    let out = child.wait_with_output().expect("pandoc wait");
    assert!(out.status.success(), "pandoc {args:?} failed");
    String::from_utf8(out.stdout).expect("utf8")
}

/// Apply normalizations for unavoidable HTML round-trip losses so our result
/// can be compared to the fixture semantically.
fn normalize_for_html(s: &str) -> String {
    // OrderedList delimiter style is not representable in HTML — the reader
    // always produces DefaultDelim.
    s.replace(", Period )", ", DefaultDelim )")
        .replace(", OneParen )", ", DefaultDelim )")
        .replace(", TwoParens )", ", DefaultDelim )")
}

fn all_fixtures() -> Vec<PathBuf> {
    let mut out = Vec::new();
    for dir in [fixtures_root(), fixtures_root().join("djot")] {
        for entry in std::fs::read_dir(&dir).unwrap().flatten() {
            let p = entry.path();
            if p.extension().and_then(|s| s.to_str()) == Some("native") {
                out.push(p);
            }
        }
    }
    out.sort();
    out
}

/// Fixtures containing constructs HTML cannot preserve losslessly
/// (Quoted, Math, RawInline/RawBlock). Tested only as smoke tests.
const SMOKE_ONLY: &[&str] = &[
    "escapes.native",
    "inlines.native",
    "blocks.native",   // djot/blocks.native — RawBlock html
    // djot/inlines: Quoted + Math + RawInline html
];

fn is_smoke_only(path: &Path) -> bool {
    let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
    if SMOKE_ONLY.contains(&name) {
        return true;
    }
    // djot/inlines.native shares a name with tests/fixtures/inlines.native;
    // distinguish by parent dir.
    let parent = path
        .parent()
        .and_then(|p| p.file_name())
        .and_then(|s| s.to_str())
        .unwrap_or("");
    parent == "djot" && name == "inlines.native"
}

#[test]
fn round_trip_semantic_parity() {
    if !pandoc_available() {
        eprintln!("note: pandoc not on PATH — skipping HTML round-trip parity test");
        return;
    }
    let fixtures = all_fixtures();
    assert!(!fixtures.is_empty(), "no fixtures found");
    let mut failures: Vec<String> = Vec::new();
    for fx in fixtures {
        let name = fx
            .strip_prefix(fixtures_root())
            .unwrap()
            .display()
            .to_string();

        let our_html = run_minipandoc(&["-f", "native", "-t", "html"], &fx);
        assert!(!our_html.trim().is_empty(), "{name}: empty HTML output");

        // Parse our HTML back to native AST (disable auto_identifiers so
        // auto-generated Header ids don't appear).
        let our_native = run_pandoc(
            &["-f", "html-auto_identifiers", "-t", "native"],
            our_html.as_bytes(),
        );
        // Normalize both sides through pandoc-native so whitespace/layout
        // differences don't matter.
        let our_norm = run_pandoc(
            &["-f", "native", "-t", "native"],
            our_native.as_bytes(),
        );
        let orig_norm = run_pandoc(
            &["-f", "native", "-t", "native"],
            std::fs::read(&fx).unwrap().as_slice(),
        );

        if is_smoke_only(&fx) {
            // Only require the HTML was accepted by pandoc and produced
            // some AST. Content equality isn't expected for these.
            assert!(
                !our_norm.trim().is_empty(),
                "{name}: smoke test — empty AST after round-trip"
            );
            continue;
        }

        let ours = normalize_for_html(&our_norm);
        let orig = normalize_for_html(&orig_norm);
        if ours != orig {
            failures.push(format!(
                "--- {name} ---\n--- ours ---\n{ours}\n--- original ---\n{orig}\n"
            ));
        }
    }
    if !failures.is_empty() {
        panic!(
            "{} fixture(s) failed HTML round-trip:\n\n{}",
            failures.len(),
            failures.join("\n")
        );
    }
}

#[test]
fn html_appears_in_list_formats() {
    let out = Command::new(binary_path())
        .arg("--list-output-formats")
        .output()
        .expect("spawn minipandoc");
    assert!(out.status.success());
    let text = String::from_utf8(out.stdout).unwrap();
    assert!(
        text.lines().any(|l| l.trim() == "html"),
        "expected 'html' in output formats: {text}"
    );
}

#[test]
fn standalone_wraps_in_html5_shell() {
    if !pandoc_available() {
        eprintln!("note: pandoc not on PATH — skipping standalone smoke test");
        return;
    }
    let fx = fixtures_root().join("meta.native");
    let html = run_minipandoc(&["-f", "native", "-t", "html", "-s"], &fx);
    assert!(
        html.starts_with("<!DOCTYPE html>"),
        "expected doctype at start of standalone output, got: {}",
        html.chars().take(80).collect::<String>()
    );
    assert!(
        html.contains("<title>A Document</title>"),
        "expected title from metadata, got:\n{html}"
    );
    assert!(html.contains("</html>"), "expected closing </html> tag");
}
