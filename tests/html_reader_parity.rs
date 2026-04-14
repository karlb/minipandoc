//! HTML reader parity.
//!
//! Three checks:
//!   1. Self round-trip: for each `.native` fixture, `minipandoc -f native
//!      -t html | minipandoc -f html -t native` should equal the fixture
//!      up to unavoidable HTML round-trip losses (OrderedList delimiter
//!      style, Quoted / Math / RawInline in non-HTML formats). Uses pandoc
//!      only to normalize both sides through `native -> native`.
//!   2. Parity with pandoc on hand-written `tests/fixtures/html/*.html`
//!      fixtures — our reader should produce the same AST as pandoc's HTML
//!      reader. `basic.html` (pandoc's syntax-highlighted sourceCode soup)
//!      is smoke-tested only.
//!   3. `html` appears in `--list-input-formats`.
//!   4. Meta extraction smoke test: a standalone document's <title>
//!      becomes `meta.title`.
//!
//! Skips pandoc-dependent tests gracefully when pandoc is absent.

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

fn run_minipandoc(args: &[&str], input_path: Option<&Path>, stdin_bytes: Option<&[u8]>) -> String {
    use std::io::Write;
    let mut cmd = Command::new(binary_path());
    cmd.args(args);
    if let Some(p) = input_path {
        cmd.arg(p);
    }
    cmd.stderr(Stdio::inherit())
        .stdout(Stdio::piped());
    if stdin_bytes.is_some() {
        cmd.stdin(Stdio::piped());
    }
    let mut child = cmd.spawn().expect("spawn minipandoc");
    if let Some(b) = stdin_bytes {
        child.stdin.as_mut().unwrap().write_all(b).unwrap();
    }
    let out = child.wait_with_output().expect("wait minipandoc");
    assert!(
        out.status.success(),
        "minipandoc failed: args={args:?}: {}",
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

/// Normalize unavoidable HTML round-trip losses.
fn normalize_for_html(s: &str) -> String {
    s.replace(", Period )", ", DefaultDelim )")
        .replace(", OneParen )", ", DefaultDelim )")
        .replace(", TwoParens )", ", DefaultDelim )")
}

fn all_native_fixtures() -> Vec<PathBuf> {
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

/// Fixtures whose native AST contains constructs HTML can't round-trip
/// losslessly (Quoted, Math as LaTeX, RawInline/RawBlock).
const SMOKE_ONLY_SELF: &[&str] = &[
    "escapes.native",
    "inlines.native",
    "blocks.native", // djot/blocks.native — RawBlock html
];

fn is_smoke_only_self(path: &Path) -> bool {
    let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
    if SMOKE_ONLY_SELF.contains(&name) {
        return true;
    }
    // djot/inlines.native shares a name with tests/fixtures/inlines.native.
    let parent = path
        .parent()
        .and_then(|p| p.file_name())
        .and_then(|s| s.to_str())
        .unwrap_or("");
    parent == "djot" && name == "inlines.native"
}

#[test]
fn self_round_trip() {
    if !pandoc_available() {
        eprintln!("note: pandoc not on PATH — skipping HTML reader self-round-trip");
        return;
    }
    let fixtures = all_native_fixtures();
    assert!(!fixtures.is_empty(), "no fixtures found");
    let mut failures: Vec<String> = Vec::new();
    for fx in fixtures {
        if is_smoke_only_self(&fx) {
            continue;
        }
        let name = fx
            .strip_prefix(fixtures_root())
            .unwrap()
            .display()
            .to_string();

        let our_html = run_minipandoc(&["-f", "native", "-t", "html"], Some(&fx), None);
        let our_native = run_minipandoc(
            &["-f", "html", "-t", "native"],
            None,
            Some(our_html.as_bytes()),
        );
        let our_norm = run_pandoc(&["-f", "native", "-t", "native"], our_native.as_bytes());
        let orig_norm = run_pandoc(
            &["-f", "native", "-t", "native"],
            std::fs::read(&fx).unwrap().as_slice(),
        );
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
            "{} fixture(s) failed HTML reader self round-trip:\n\n{}",
            failures.len(),
            failures.join("\n")
        );
    }
}

/// Hand-written HTML fixtures under `tests/fixtures/html/` that match
/// pandoc's HTML reader semantics. `basic.html` contains pandoc's
/// syntax-highlighted sourceCode spans and is smoke-tested only.
const SMOKE_ONLY_PANDOC: &[&str] = &["basic.html"];

fn is_smoke_only_pandoc(path: &Path) -> bool {
    let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
    SMOKE_ONLY_PANDOC.contains(&name)
}

fn html_fixtures() -> Vec<PathBuf> {
    let dir = fixtures_root().join("html");
    let mut out: Vec<_> = std::fs::read_dir(&dir)
        .unwrap()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("html"))
        .collect();
    out.sort();
    out
}

#[test]
fn reader_parity_with_pandoc() {
    if !pandoc_available() {
        eprintln!("note: pandoc not on PATH — skipping HTML reader pandoc-parity test");
        return;
    }
    let fixtures = html_fixtures();
    assert!(!fixtures.is_empty(), "no html/ fixtures found");
    let mut failures: Vec<String> = Vec::new();
    for fx in fixtures {
        let name = fx.file_name().unwrap().to_string_lossy().into_owned();
        let ours_raw = run_minipandoc(&["-f", "html", "-t", "native"], Some(&fx), None);

        if is_smoke_only_pandoc(&fx) {
            // Smoke check: reader must produce something non-empty.
            assert!(!ours_raw.trim().is_empty(), "{name}: empty AST from reader");
            // For basic.html specifically, verify the CodeBlock with language
            // class is recovered — this is the main loss in sourceCode soup.
            if name == "basic.html" {
                assert!(
                    ours_raw.contains("CodeBlock") && ours_raw.contains("python"),
                    "basic.html: expected CodeBlock with python lang, got:\n{ours_raw}"
                );
                assert!(
                    ours_raw.contains("print(\\\"hi\\\")"),
                    "basic.html: expected print(\"hi\") in CodeBlock, got:\n{ours_raw}"
                );
            }
            continue;
        }

        let theirs_raw = run_pandoc(
            &["-f", "html-auto_identifiers", "-t", "native"],
            std::fs::read(&fx).unwrap().as_slice(),
        );
        let ours = run_pandoc(&["-f", "native", "-t", "native"], ours_raw.as_bytes());
        let theirs = run_pandoc(&["-f", "native", "-t", "native"], theirs_raw.as_bytes());
        if ours != theirs {
            failures.push(format!(
                "--- {name} ---\n--- ours ---\n{ours}\n--- pandoc ---\n{theirs}\n"
            ));
        }
    }
    if !failures.is_empty() {
        panic!(
            "{} fixture(s) diverged from pandoc HTML reader:\n\n{}",
            failures.len(),
            failures.join("\n")
        );
    }
}

#[test]
fn meta_extraction_smoke() {
    let input = "<html><head><title>Greetings</title></head><body><p>Hi.</p></body></html>";
    let out = run_minipandoc(
        &["-f", "html", "-t", "native", "--standalone"],
        None,
        Some(input.as_bytes()),
    );
    assert!(
        out.contains("Pandoc Meta"),
        "expected 'Pandoc Meta' in standalone output, got:\n{out}"
    );
    assert!(
        out.contains("Str \"Greetings\""),
        "expected title 'Greetings' in meta, got:\n{out}"
    );
}

#[test]
fn html_appears_in_list_input_formats() {
    let out = Command::new(binary_path())
        .arg("--list-input-formats")
        .output()
        .expect("spawn minipandoc");
    assert!(out.status.success());
    let text = String::from_utf8(out.stdout).unwrap();
    assert!(
        text.lines().any(|l| l.trim() == "html"),
        "expected 'html' in input formats: {text}"
    );
}
