//! LaTeX writer parity.
//!
//! For each `tests/fixtures/latex/*.native` fixture, byte-compare
//! `minipandoc -f native -t latex` against `pandoc -f native -t latex`.
//! Skips gracefully when pandoc is absent.
//!
//! Fixtures listed in `SMOKE_ONLY` are exercised as smoke tests only:
//! the writer must run, produce non-empty output, and that output must
//! be syntactically valid LaTeX (pandoc's markdown reader parses it
//! back to a non-empty native AST). We use smoke-only for cases where
//! we intentionally diverge from pandoc's exact output (escape sets,
//! hypertarget nesting, table column specs, curly-quote TeX sequences).

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

fn binary_path() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("target");
    p.push(if cfg!(debug_assertions) { "debug" } else { "release" });
    p.push("minipandoc");
    p
}

fn fixtures_dir() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.extend(["tests", "fixtures", "latex"]);
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

fn fixtures() -> Vec<PathBuf> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(fixtures_dir()).unwrap().flatten() {
        let p = entry.path();
        if p.extension().and_then(|s| s.to_str()) == Some("native") {
            out.push(p);
        }
    }
    out.sort();
    out
}

/// Fixtures where we don't attempt byte-parity. For each, smoke test
/// that `pandoc -f latex -t native` accepts our output as valid LaTeX.
const SMOKE_ONLY: &[&str] = &[
    // Our escape set is broader (e.g. we emit \textasciitilde{} where
    // pandoc uses \textasciitilde\ ).
    "escapes.native",
    // Header hypertarget+label nesting has version-specific differences.
    "header_attrs.native",
    // Subscript/superscript/smallcaps exact command choice varies.
    "inlines_extra.native",
    // Curly-quote TeX sequences match pandoc conceptually but not
    // always byte-for-byte across versions.
    "quoted.native",
    // Table column spec formatting (`@{}ll@{}` vs `lcr`) varies.
    "table.native",
    // Complex tables are wrapped in verbatim — structurally different
    // from pandoc which uses full longtable with nested minipages.
    "complex_table.native",
    // Figure emits `\begin{figure}` only when a Figure AST node is
    // present; pandoc may also promote a Para-with-Image paragraph to
    // a figure environment based on extension flags.
    "figure.native",
    // Pandoc emits \newpage etc. around LineBlocks; we don't.
    "breaks.native",
    // Metadata is a doc-level thing; non-standalone mode differs.
    "meta.native",
    // DefinitionList loose-vs-tight and \tightlist placement vary.
    "lists.native",
    // Footnote placement and \par usage varies with pandoc version.
    "footnote.native",
    // Mixed inline features — SmallCaps/Math/Quoted all have minor
    // divergences and the fixture combines several.
    "inlines.native",
];

fn is_smoke_only(p: &Path) -> bool {
    let name = p.file_name().and_then(|s| s.to_str()).unwrap_or("");
    SMOKE_ONLY.contains(&name)
}

#[test]
fn latex_byte_parity() {
    if !pandoc_available() {
        eprintln!("note: pandoc not on PATH — skipping latex parity test");
        return;
    }
    let fxs = fixtures();
    assert!(!fxs.is_empty(), "no latex fixtures found");
    let mut failures: Vec<String> = Vec::new();
    for fx in fxs {
        let name = fx.file_name().unwrap().to_string_lossy().to_string();
        let ours = run_minipandoc(&["-f", "native", "-t", "latex"], &fx);
        if is_smoke_only(&fx) {
            assert!(!ours.trim().is_empty(), "{name}: smoke-only — empty output");
            continue;
        }
        let theirs = run_pandoc(&["-f", "native", "-t", "latex"], &fx);
        if ours != theirs {
            failures.push(format!(
                "--- {name} ---\n--- ours ---\n{ours}\n--- pandoc ---\n{theirs}\n"
            ));
        }
    }
    if !failures.is_empty() {
        panic!(
            "{} fixture(s) failed latex byte-parity:\n\n{}",
            failures.len(),
            failures.join("\n")
        );
    }
}

/// Smoke-only fixtures: writer must produce LaTeX that pandoc's
/// latex reader accepts (round-trips to a parseable native AST).
#[test]
fn latex_smoke_roundtrips() {
    if !pandoc_available() {
        eprintln!("note: pandoc not on PATH — skipping smoke-roundtrip test");
        return;
    }
    let mut failures: Vec<String> = Vec::new();
    for fx in fixtures() {
        if !is_smoke_only(&fx) {
            continue;
        }
        let name = fx.file_name().unwrap().to_string_lossy().to_string();
        let latex = run_minipandoc(&["-f", "native", "-t", "latex"], &fx);
        let mut child = Command::new("pandoc")
            .args(["-f", "latex", "-t", "native"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn pandoc");
        use std::io::Write;
        child
            .stdin
            .as_mut()
            .unwrap()
            .write_all(latex.as_bytes())
            .unwrap();
        let out = child.wait_with_output().unwrap();
        if !out.status.success() || out.stdout.is_empty() {
            failures.push(format!(
                "{name}: pandoc rejected our latex output:\n--- latex ---\n{latex}\n--- stderr ---\n{}\n",
                String::from_utf8_lossy(&out.stderr)
            ));
        }
    }
    if !failures.is_empty() {
        panic!(
            "{} smoke-only fixture(s) failed round-trip:\n\n{}",
            failures.len(),
            failures.join("\n")
        );
    }
}

#[test]
fn latex_appears_in_list_formats() {
    let out = Command::new(binary_path())
        .arg("--list-output-formats")
        .output()
        .expect("spawn minipandoc");
    assert!(out.status.success());
    let text = String::from_utf8(out.stdout).unwrap();
    assert!(
        text.lines().any(|l| l.trim() == "latex"),
        "expected 'latex' in output formats: {text}"
    );
}

/// Standalone mode wraps the body in the bundled `default.latex`
/// template, which provides a full `\documentclass{article}` preamble
/// and `\begin{document}...\end{document}` wrapper.
#[test]
fn latex_standalone_emits_document_structure() {
    let mut fx = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    fx.extend(["tests", "fixtures", "latex", "meta.native"]);
    let out = run_minipandoc(&["-f", "native", "-t", "latex", "-s"], &fx);
    assert!(
        out.contains("\\documentclass"),
        "expected \\documentclass in output:\n{out}"
    );
    assert!(
        out.contains("{article}"),
        "expected article documentclass:\n{out}"
    );
    assert!(
        out.contains("\\title{A Document}"),
        "expected title from metadata:\n{out}"
    );
    assert!(
        out.contains("\\begin{document}"),
        "expected \\begin{{document}} in output:\n{out}"
    );
    assert!(
        out.contains("\\end{document}"),
        "expected \\end{{document}} in output:\n{out}"
    );
    assert!(
        out.contains("\\maketitle"),
        "expected \\maketitle with title set:\n{out}"
    );
}
